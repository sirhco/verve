# Draco test fixtures

Real (non-synthetic) Draco-compressed geometry, generated once offline via the
reference `draco3dgltf` encoder/decoder and committed here so the Zig decoder
tests can assert against an authoritative stream instead of a hand-rolled one.

## Files

- `quad.glb` — a complete glTF-Binary containing one mesh (one primitive) with
  `KHR_draco_mesh_compression`. Reserved for Slice D (full glTF+Draco
  pipeline integration).
- `quad.drc` — the raw Draco bitstream extracted from `quad.glb` (everything
  from the `DRACO` magic to end-of-buffer; trailing bytes past the encoded
  primitive are ignored by the decoder). This is what Slice A's
  `parseHeader` / Slice B's decoder consume directly.
- `quad.golden.json` — the reference-decoded result (`indices`, `POSITION`)
  produced by decoding `quad.glb` back through `@gltf-transform/core` +
  `draco3dgltf`. Consumed by Slices B/C to assert the from-scratch Zig
  decoder matches the reference decoder bit-for-bit (after accounting for
  Draco's internal vertex reordering).
- `cube.{glb,drc,golden.json}` — same shape as the `quad.*` trio, but for an
  8-vertex, 12-triangle cube. `quad` and `cube` are both genus-0 meshes, so
  neither exercises the edgebreaker `TOPOLOGY_S` / topology-split path (0
  split symbols in both streams).
- `torus.{glb,drc,golden.json}` — a genus-1 mesh (parametric torus, 12 major
  x 8 minor segments, `R=2 r=0.7`, 96 vertices / 192 triangles — see
  `tools/dev/draco_gen.mjs`'s `buildTorus`). Its real encoded stream carries
  8 split symbols across 2 topology-split events, so this is the fixture
  that exercises the `.s` traversal-symbol arm and the
  `isTopologySplit`/active-corner re-injection logic — the hardest part of
  the decoder and the one `quad`/`cube` cannot reach. Slice B's golden test
  additionally asserts `num_encoded_split_symbols > 0` on this fixture to
  prove the split path actually ran, not just that the final indices match.

## Source meshes

`quad` — a 4-vertex quad, 2 triangles:

- POSITION: `[0,0,0, 1,0,0, 1,1,0, 0,1,0]` (4 × vec3)
- indices: `[0,1,2, 0,2,3]` (2 triangles, CCW)

`cube` — an 8-vertex cube, 12 triangles:

- POSITION: `[-1,-1,-1, 1,-1,-1, 1,1,-1, -1,1,-1, -1,-1,1, 1,-1,1, 1,1,1, -1,1,1]`
- indices: `[0,2,1, 0,3,2, 4,5,6, 4,6,7, 0,1,5, 0,5,4, 2,3,7, 2,7,6, 1,2,6, 1,6,5, 0,4,7, 0,7,3]`

`torus` — a 96-vertex, 192-triangle parametric torus (12 major x 8 minor
segments, `R=2 r=0.7`; generated procedurally by `buildTorus` in the
generator, not hand-listed here).

All three are encoded with method `EDGEBREAKER` (Draco's
connectivity-compression mode, as opposed to `SEQUENTIAL`). Draco reorders
vertices during encoding, so the reference-decoded indices differ from the
input — e.g. quad's input `[0,1,2, 0,2,3]` decodes to `[0,1,2,1,3,2]` (see
`quad.golden.json`; `cube.golden.json` / `torus.golden.json` are the same
idea).

## Bitstream

Draco bitstream version **2.2** for all three fixtures (`<name>.drc` bytes
5-6 are `02 02`), method byte `01` = `EDGEBREAKER`, geometry-type byte `01` =
`TRIANGULAR_MESH`. First bytes: `44 52 41 43 4f 02 02 01 01 ...` (`DRACO`,
major=2, minor=2, encoder_method=1, encoder_type=1).

## Provenance

- Generator: `tools/dev/draco_gen.mjs` (offline dev tool — **not** run by
  `build.zig`; requires npm deps that are not a repo dependency).
- Libraries used to generate: `@gltf-transform/core`, `@gltf-transform/extensions`,
  `draco3dgltf` (draco3dgltf 1.5.7 at generation time — bundles Draco's
  reference `EDGEBREAKER` encoder and matching decoder, bitstream v2.2).

## Regenerate

```bash
mkdir -p /tmp/draco-gen && cd /tmp/draco-gen
npm i @gltf-transform/core @gltf-transform/extensions draco3dgltf
NODE_PATH=/tmp/draco-gen/node_modules node /path/to/verve/tools/dev/draco_gen.mjs /path/to/verve/tests/fixtures/draco
```

Note: Node's ESM resolver ignores `NODE_PATH` for bare-specifier imports, so
in practice either run the generator from a directory containing (or
symlinking) the installed `node_modules`, or copy it there before running.
