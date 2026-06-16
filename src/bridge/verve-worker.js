// verve.gl asset-loader worker. Fetches a gl asset off the main thread and
// transfers the bytes back; an optional decode step (passthrough today) is the
// hook for future compressed-format transcoding (KTX2/Basis/JPEG → RGBA).
// Served same-origin at /verve-worker.js; spawned lazily by verve.js. No imports.

// Image decoders: compressed bytes → [w:u32 LE][h:u32 LE][RGBA…]. createImageBitmap
// is zero-dep + works in web + all desktop webviews; runs off the main thread here.
async function decodeImage(buf) {
  const bm = await createImageBitmap(new Blob([buf]));
  const c = new OffscreenCanvas(bm.width, bm.height);
  const cx = c.getContext("2d");
  cx.drawImage(bm, 0, 0);
  const px = cx.getImageData(0, 0, bm.width, bm.height).data; // RGBA Uint8ClampedArray
  const out = new Uint8Array(8 + px.length);
  const dv = new DataView(out.buffer);
  dv.setUint32(0, bm.width, true);
  dv.setUint32(4, bm.height, true);
  out.set(px, 8);
  bm.close();
  return out.buffer;
}
const decoders = { png: decodeImage, jpg: decodeImage, jpeg: decodeImage, webp: decodeImage };

async function decode(url, buf) {
  const dot = url.lastIndexOf(".");
  const ext = dot >= 0 ? url.slice(dot + 1).toLowerCase() : "";
  const fn = decoders[ext];
  return fn ? await fn(buf) : buf; // passthrough
}

self.onmessage = async (e) => {
  const { id, url } = e.data || {};
  try {
    const r = await fetch(url);
    if (!r.ok) throw new Error("HTTP " + r.status);
    let buf = await r.arrayBuffer();
    buf = await decode(url, buf);
    self.postMessage({ id, ok: true, buffer: buf }, [buf]);
  } catch (err) {
    self.postMessage({ id, ok: false, err: String(err) });
  }
};
