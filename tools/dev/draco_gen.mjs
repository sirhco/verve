// OFFLINE dev tool — run by hand, NOT by build.zig. Regenerates the committed
// Draco fixtures + golden. Requires (in a scratch dir, not the repo):
//   npm i @gltf-transform/core @gltf-transform/extensions draco3dgltf
// Usage: node tools/dev/draco_gen.mjs <out_dir>
import { Document, WebIO } from '@gltf-transform/core';
import { KHRDracoMeshCompression } from '@gltf-transform/extensions';
import draco3d from 'draco3dgltf';
import { writeFileSync } from 'node:fs';

const outDir = process.argv[2] ?? '.';
const doc = new Document(); const buf = doc.createBuffer();
const pos = doc.createAccessor().setType('VEC3').setArray(new Float32Array([0,0,0,1,0,0,1,1,0,0,1,0])).setBuffer(buf);
const idx = doc.createAccessor().setType('SCALAR').setArray(new Uint16Array([0,1,2,0,2,3])).setBuffer(buf);
const prim = doc.createPrimitive().setAttribute('POSITION', pos).setIndices(idx);
doc.createScene().addChild(doc.createNode().setMesh(doc.createMesh().addPrimitive(prim)));
const io = new WebIO().registerExtensions([KHRDracoMeshCompression]).registerDependencies({
  'draco3d.encoder': await draco3d.createEncoderModule(),
  'draco3d.decoder': await draco3d.createDecoderModule(),
});
doc.createExtension(KHRDracoMeshCompression).setRequired(true)
  .setEncoderOptions({ method: KHRDracoMeshCompression.EncoderMethod.EDGEBREAKER });
const glb = await io.writeBinary(doc);
writeFileSync(`${outDir}/quad.glb`, Buffer.from(glb));
// Extract the raw Draco buffer (starts at the "DRACO" magic).
const b = Buffer.from(glb); const s = b.indexOf('DRACO');
writeFileSync(`${outDir}/quad.drc`, b.subarray(s)); // trailing bytes past the primitive are ignored by the decoder
// Golden: decode via the reference lib.
const doc2 = await io.readBinary(glb);
const p2 = doc2.getRoot().listMeshes()[0].listPrimitives()[0];
writeFileSync(`${outDir}/quad.golden.json`, JSON.stringify({
  indices: Array.from(p2.getIndices().getArray()),
  POSITION: Array.from(p2.getAttribute('POSITION').getArray()),
}, null, 2));
console.log('wrote quad.glb / quad.drc / quad.golden.json');
