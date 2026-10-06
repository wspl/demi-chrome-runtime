// Checks a running Chrome over CDP: the extension, every font check in
// fonts.json, a screenshot, printing, media and TLS. Compiled with
// `bun build --compile` into a binary that needs only glibc, so a bare
// container needs nothing besides Chrome and the runtime to run it.
//
// Usage: probe <port> <fonts.json> <page url> <out dir>
// Writes <out>/result.json, screenshot.png and page.pdf; exits 1 on any failure.
import { readFileSync, writeFileSync } from 'node:fs';

type Check = { css?: string; lang?: string; sample: string; chars: string; expect: string[]; color?: boolean };

const [port, fontsJson, pageUrl, out] = process.argv.slice(2);
const checks: Check[] = JSON.parse(readFileSync(fontsJson, 'utf8')).fonts.flatMap((font: { checks: Check[] }) => font.checks);
const result: Record<string, unknown> = {};
const failures: string[] = [];

function finish(code: number): never {
  result.failures = failures;
  writeFileSync(`${out}/result.json`, JSON.stringify(result, null, 1));
  console.log(failures.length ? `FAILED:\n  ${failures.join('\n  ')}` : 'all checks passed');
  process.exit(code);
}

const deadline = setTimeout(() => {
  failures.push('timed out after 180 s');
  finish(1);
}, 180_000);

async function version(): Promise<{ webSocketDebuggerUrl: string; Browser: string }> {
  for (let i = 0; i < 300; i++) {
    try {
      return await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
    } catch {
      await Bun.sleep(100);
    }
  }
  throw new Error('Chrome opened no DevTools endpoint in 30 s');
}

const info = await version();
result.browser = info.Browser;
const socket = new WebSocket(info.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.onopen = resolve;
  socket.onerror = reject;
});
let next = 1;
const pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void }>();
socket.onmessage = event => {
  const message = JSON.parse(String(event.data));
  if (message.id === undefined) {
    return;
  }
  const waiter = pending.get(message.id);
  pending.delete(message.id);
  if (message.error) {
    waiter?.reject(new Error(`${message.error.message} ${message.error.data ?? ''}`));
  } else {
    waiter?.resolve(message.result);
  }
};

// A call that gets no reply in 30 s fails with its method: a crashed
// renderer never answers.
function send(method: string, params: object = {}, sessionId?: string): Promise<any> {
  const id = next++;
  socket.send(JSON.stringify({ id, method, params, sessionId }));
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`${method} ${JSON.stringify(params).slice(0, 80)}: no reply in 30 s`));
    }, 30_000);
    pending.set(id, {
      resolve: value => { clearTimeout(timer); resolve(value); },
      reject: error => { clearTimeout(timer); reject(error); },
    });
  });
}

async function evaluate(sessionId: string, expression: string) {
  const reply = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
  if (reply.exceptionDetails) {
    throw new Error(JSON.stringify(reply.exceptionDetails));
  }
  return reply.result.value;
}

async function open(url: string) {
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  await send('Page.enable', {}, sessionId);
  const navigation = await send('Page.navigate', { url }, sessionId);
  for (let i = 0; i < 100 && (await evaluate(sessionId, 'document.readyState')) !== 'complete'; i++) {
    await Bun.sleep(100);
  }
  return { sessionId, navigation };
}

// The MV3 extension's service worker and the offscreen document it creates,
// which reports whether WebCodecs can encode H.264 there.
async function extension() {
  for (let i = 0; i < 150; i++) {
    const { targetInfos } = await send('Target.getTargets');
    const offscreen = targetInfos.find((t: any) => t.url.startsWith('chrome-extension://') && t.url.endsWith('/offscreen.html'));
    const origin = offscreen?.url.replace('/offscreen.html', '');
    const worker = offscreen && targetInfos.find((t: any) => t.type === 'service_worker' && t.url === `${origin}/background.js`);
    if (worker && offscreen) {
      const { sessionId } = await send('Target.attachToTarget', { targetId: offscreen.targetId, flatten: true });
      for (let j = 0; j < 100; j++) {
        const title = await evaluate(sessionId, 'document.title');
        if (title.startsWith('offscreen ')) {
          return { worker: worker.url, offscreen: offscreen.url, title };
        }
        await Bun.sleep(100);
      }
      return { worker: worker.url, offscreen: offscreen.url, title: 'no result' };
    }
    await Bun.sleep(100);
  }
  return { title: 'extension targets not found' };
}

try {
  const loaded = await extension();
  result.extension = loaded;
  if (loaded.title !== 'offscreen h264=true') {
    failures.push(`extension: ${loaded.title}`);
  }

  const { sessionId } = await open(pageUrl);
  await send('Emulation.setDeviceMetricsOverride', { width: 1132, height: 800, deviceScaleFactor: 1, mobile: false }, sessionId);
  await evaluate(sessionId, `window.show(${JSON.stringify(checks)})`);
  await send('DOM.enable', {}, sessionId);
  await send('CSS.enable', {}, sessionId);
  const { root } = await send('DOM.getDocument', {}, sessionId);
  const fonts: Record<string, unknown>[] = [];
  for (const [index, check] of checks.entries()) {
    const { nodeId } = await send('DOM.querySelector', { nodeId: root.nodeId, selector: `#check-${index}` }, sessionId);
    const { fonts: used } = await send('CSS.getPlatformFontsForNode', { nodeId }, sessionId);
    const families = used.map((font: any) => `${font.familyName}${font.isCustomFont ? '*' : ''}(${font.glyphCount})`);
    const drawn = await evaluate(sessionId, `window.inspect(${index}, ${JSON.stringify(check.chars)})`);
    const name = `${check.expect[0]}${check.lang ? ` [${check.lang}]` : ''}`;
    fonts.push({ name, families, ...drawn });
    if (!used.some((font: any) => check.expect.includes(font.familyName))) {
      failures.push(`${name}: drawn with ${families.join(', ')}, expected ${check.expect.join(' or ')}`);
    }
    if (drawn.letters === 0) {
      failures.push(`${name}: no characters match ${check.chars}`);
    }
    if (drawn.notdef.length || drawn.blank.length) {
      failures.push(`${name}: .notdef for ${drawn.notdef.join('')}, blank for ${drawn.blank.join('')}`);
    }
    if (check.color && drawn.colored === 0) {
      failures.push(`${name}: no character drawn in color`);
    }
  }
  result.fonts = fonts;

  const media = await evaluate(sessionId, 'window.media');
  result.media = media;
  const encoded = media.webcodecs;
  if (!encoded.encodeSupported || encoded.chunks !== 10 || encoded.key < 1 || encoded.failure) {
    failures.push(`webcodecs: ${JSON.stringify(encoded)}`);
  }
  if (media.audio.error || media.audio.paused || !(media.audio.currentTime > 0)) {
    failures.push(`audio: ${JSON.stringify(media.audio)}`);
  }
  if (media.video.error || !(media.video.currentTime > 0)) {
    failures.push(`video: ${JSON.stringify(media.video)}`);
  }

  const { cssContentSize } = await send('Page.getLayoutMetrics', {}, sessionId);
  const shot = await send('Page.captureScreenshot', {
    format: 'png',
    captureBeyondViewport: true,
    clip: { x: 0, y: 0, width: cssContentSize.width, height: cssContentSize.height, scale: 1 },
  }, sessionId);
  writeFileSync(`${out}/screenshot.png`, Buffer.from(shot.data, 'base64'));

  // The PDF embeds the fonts the page used; their PostScript names show which.
  const pdf = Buffer.from((await send('Page.printToPDF', { printBackground: true }, sessionId)).data, 'base64');
  writeFileSync(`${out}/page.pdf`, pdf);
  const embedded = [...new Set([...pdf.toString('latin1').matchAll(/\/BaseFont\s*\/(?:[A-Z]{6}\+)?([^\s/\]>]+)/g)].map(m => m[1]))].sort();
  result.pdf = { bytes: pdf.length, header: pdf.subarray(0, 5).toString(), fonts: embedded };
  if (pdf.subarray(0, 5).toString() !== '%PDF-') {
    failures.push('pdf: not a PDF');
  }
  // CFF fonts (Noto Sans CJK) and color emoji are drawn as Type 3 fonts, which have no name.
  for (const expected of ['LiberationSans', 'NotoSansArabic', 'NotoSansDevanagari']) {
    if (!embedded.some(name => name.startsWith(expected))) {
      failures.push(`pdf: no ${expected} font embedded (${embedded.join(', ')})`);
    }
  }

  // TLS: Chrome verifies with its own root store through the runtime's NSS.
  const tls = await open('https://example.com/');
  const title = await evaluate(tls.sessionId, 'document.title');
  result.https = { errorText: tls.navigation.errorText ?? null, title };
  if (tls.navigation.errorText || title !== 'Example Domain') {
    failures.push(`https: ${JSON.stringify(result.https)}`);
  }
} catch (error) {
  failures.push(String(error));
}
await send('Browser.close').catch(() => {});
clearTimeout(deadline);
finish(failures.length ? 1 : 0);
