// verve.gl asset-loader worker. Fetches a gl asset off the main thread and
// transfers the bytes back; an optional decode step (passthrough today) is the
// hook for future compressed-format transcoding (KTX2/Basis/JPEG → RGBA).
// Served same-origin at /verve-worker.js; spawned lazily by verve.js. No imports.

// ext → (ArrayBuffer) => ArrayBuffer. Empty today: .vmesh/.venv are pre-baked, so
// decode is identity. The compressed-textures feature registers real decoders here.
const decoders = {};

function decode(url, buf) {
  const dot = url.lastIndexOf(".");
  const ext = dot >= 0 ? url.slice(dot + 1).toLowerCase() : "";
  const fn = decoders[ext];
  return fn ? fn(buf) : buf; // passthrough
}

self.onmessage = async (e) => {
  const { id, url } = e.data || {};
  try {
    const r = await fetch(url);
    if (!r.ok) throw new Error("HTTP " + r.status);
    let buf = await r.arrayBuffer();
    buf = decode(url, buf);
    self.postMessage({ id, ok: true, buffer: buf }, [buf]);
  } catch (err) {
    self.postMessage({ id, ok: false, err: String(err) });
  }
};
