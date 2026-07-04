// OFFLINE dev tool — run by hand, NOT by build.zig. Regenerates the committed
// Draco fixtures + goldens. Requires (in a scratch dir, not the repo):
//   npm i @gltf-transform/core @gltf-transform/extensions draco3dgltf
// Usage: node tools/dev/draco_gen.mjs <out_dir>
import { Document, WebIO } from '@gltf-transform/core';
import { KHRDracoMeshCompression } from '@gltf-transform/extensions';
import draco3d from 'draco3dgltf';
import { writeFileSync } from 'node:fs';

const outDir = process.argv[2] ?? '.';
const io = new WebIO().registerExtensions([KHRDracoMeshCompression]).registerDependencies({
  'draco3d.encoder': await draco3d.createEncoderModule(),
  'draco3d.decoder': await draco3d.createDecoderModule(),
});

/// Build a glTF doc with one indexed triangle-mesh primitive from flat
/// `positions`/`indices` arrays (plus optional per-vertex `normals`/`uvs`),
/// EDGEBREAKER-compress it, write `<name>.{glb,drc,golden.json}` into
/// `outDir`. The golden is produced by decoding the just-encoded glb back
/// through the same reference (`draco3dgltf`) decoder — Draco reorders
/// vertices during encoding, so the golden captures the *decoded*
/// (post-reorder) attributes, not the input.
async function genFixture(name, positions, indices, extra = {}) {
  const { normals, uvs } = extra;
  const doc = new Document();
  const buf = doc.createBuffer();
  const pos = doc.createAccessor().setType('VEC3').setArray(new Float32Array(positions)).setBuffer(buf);
  const idx = doc.createAccessor().setType('SCALAR').setArray(new Uint32Array(indices)).setBuffer(buf);
  const prim = doc.createPrimitive().setAttribute('POSITION', pos).setIndices(idx);
  if (normals) {
    const nrm = doc.createAccessor().setType('VEC3').setArray(new Float32Array(normals)).setBuffer(buf);
    prim.setAttribute('NORMAL', nrm);
  }
  if (uvs) {
    const uv = doc.createAccessor().setType('VEC2').setArray(new Float32Array(uvs)).setBuffer(buf);
    prim.setAttribute('TEXCOORD_0', uv);
  }
  doc.createScene().addChild(doc.createNode().setMesh(doc.createMesh().addPrimitive(prim)));
  doc.createExtension(KHRDracoMeshCompression).setRequired(true)
    .setEncoderOptions({ method: KHRDracoMeshCompression.EncoderMethod.EDGEBREAKER });

  const glb = await io.writeBinary(doc);
  writeFileSync(`${outDir}/${name}.glb`, Buffer.from(glb));
  // Extract the raw Draco buffer (starts at the "DRACO" magic).
  const b = Buffer.from(glb);
  const s = b.indexOf('DRACO');
  writeFileSync(`${outDir}/${name}.drc`, b.subarray(s)); // trailing bytes past the primitive are ignored by the decoder

  // Golden: decode via the reference lib.
  const doc2 = await io.readBinary(glb);
  const p2 = doc2.getRoot().listMeshes()[0].listPrimitives()[0];
  const golden = {
    indices: Array.from(p2.getIndices().getArray()),
    POSITION: Array.from(p2.getAttribute('POSITION').getArray()),
  };
  if (normals) golden.NORMAL = Array.from(p2.getAttribute('NORMAL').getArray());
  if (uvs) golden.TEXCOORD_0 = Array.from(p2.getAttribute('TEXCOORD_0').getArray());
  writeFileSync(`${outDir}/${name}.golden.json`, JSON.stringify(golden, null, 2));
  console.log(`wrote ${name}.glb / ${name}.drc / ${name}.golden.json`);
}

// ── quad: 4 verts, 2 tris ────────────────────────────────────────────────────
await genFixture('quad',
  [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0],
  [0, 1, 2, 0, 2, 3]);

// ── cube: 8 verts, 12 tris ───────────────────────────────────────────────────
const CUBE_P = [-1, -1, -1, 1, -1, -1, 1, 1, -1, -1, 1, -1, -1, -1, 1, 1, -1, 1, 1, 1, 1, -1, 1, 1];
const CUBE_I = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 2, 3, 7, 2, 7, 6, 1, 2, 6, 1, 6, 5, 0, 4, 7, 0, 7, 3];
await genFixture('cube', CUBE_P, CUBE_I);

// ── torus: 12x8 segments, R=2 r=0.7 — genus-1 → guaranteed to exercise the
// edgebreaker TOPOLOGY_S / topology-split path (0 splits in quad/cube leaves
// that path unexercised; this torus produces 8 split symbols / 2 topology
// events, confirmed against our own decoder — see edgebreaker.zig's torus
// golden test, which additionally asserts num_encoded_split_symbols > 0).
function buildTorus(majorSegs, minorSegs, R, r) {
  const P = [];
  for (let i = 0; i < majorSegs; i++) {
    const u = (i / majorSegs) * Math.PI * 2;
    const cu = Math.cos(u), su = Math.sin(u);
    for (let j = 0; j < minorSegs; j++) {
      const v = (j / minorSegs) * Math.PI * 2;
      const cv = Math.cos(v), sv = Math.sin(v);
      P.push((R + r * cv) * cu, (R + r * cv) * su, r * sv);
    }
  }
  const I = [];
  for (let i = 0; i < majorSegs; i++) {
    const ni = (i + 1) % majorSegs;
    for (let j = 0; j < minorSegs; j++) {
      const nj = (j + 1) % minorSegs;
      const a = i * minorSegs + j, b = ni * minorSegs + j, c = ni * minorSegs + nj, d = i * minorSegs + nj;
      I.push(a, b, c, a, c, d);
    }
  }
  return { P, I };
}
const { P: TORUS_P, I: TORUS_I } = buildTorus(12, 8, 2, 0.7);
await genFixture('torus', TORUS_P, TORUS_I);

// ── cube_nrm: same 8-vert/12-tri cube + smooth per-vertex NORMAL
// (N[i] = normalize(P[i]), valid since the cube is centered at the origin) —
// exercises multi-attribute decode (POSITION + NORMAL, num_attribute_data=1).
function normalize3(v) {
  const len = Math.hypot(v[0], v[1], v[2]);
  return [v[0] / len, v[1] / len, v[2] / len];
}
const CUBE_N = [];
for (let i = 0; i < CUBE_P.length; i += 3) {
  CUBE_N.push(...normalize3(CUBE_P.slice(i, i + 3)));
}
await genFixture('cube_nrm', CUBE_P, CUBE_I, { normals: CUBE_N });

// ── cube_nrm_uv: + TEXCOORD_0 — exercises 3-attribute decode
// (POSITION + NORMAL + TEXCOORD_0, num_attribute_data=2).
const CUBE_UV = [0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1];
await genFixture('cube_nrm_uv', CUBE_P, CUBE_I, { normals: CUBE_N, uvs: CUBE_UV });
