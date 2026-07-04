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

## Source mesh

A 4-vertex quad, 2 triangles:

- POSITION: `[0,0,0, 1,0,0, 1,1,0, 0,1,0]` (4 × vec3)
- indices: `[0,1,2, 0,2,3]` (2 triangles, CCW)

Encoded with method `EDGEBREAKER` (Draco's connectivity-compression mode, as
opposed to `SEQUENTIAL`). Draco reorders vertices during encoding, so the
reference-decoded indices differ from the input: `[0,1,2,1,3,2]` (see
`quad.golden.json`).

## Bitstream

Draco bitstream version **2.2** (`quad.drc` bytes 5-6 are `02 02`), method
byte `01` = `EDGEBREAKER`, geometry-type byte `01` = `TRIANGULAR_MESH`. First
bytes: `44 52 41 43 4f 02 02 01 01 ...` (`DRACO`, major=2, minor=2,
encoder_method=1, encoder_type=1).

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
