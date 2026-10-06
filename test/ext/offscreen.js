// Report whether WebCodecs H.264 encoding is available inside the offscreen document too.
const support = await VideoEncoder.isConfigSupported({ codec: 'avc1.640033', width: 1280, height: 720, hardwareAcceleration: 'prefer-software', latencyMode: 'realtime', avc: { format: 'annexb' } });
document.title = 'offscreen h264=' + support.supported;
