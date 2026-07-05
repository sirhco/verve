//! Pure-Zig Draco (KHR_draco_mesh_compression) decode — build-time only.
//! Slice A: container + entropy foundation. No mesh output yet.
pub const Error = error{ BadMagic, Truncated, UnsupportedDracoVersion, UnsupportedGeometry, UnsupportedDracoFeature, Corrupt, OutOfMemory };

pub const DecoderBuffer = @import("buffer.zig").DecoderBuffer;
pub const BitDecoder = @import("buffer.zig").BitDecoder;

pub const RAnsBitDecoder = @import("rans.zig").RAnsBitDecoder;
pub const decodeSymbols = @import("rans.zig").decodeSymbols;

pub const header = @import("header.zig");
pub const GeometryType = header.GeometryType;
pub const EncoderMethod = header.EncoderMethod;
pub const Header = header.Header;
pub const parseHeader = header.parseHeader;

pub const CornerTable = @import("corner_table.zig").CornerTable;
pub const MeshAttrCornerTable = @import("mesh_attr_corner_table.zig").MeshAttrCornerTable;

pub const TraversalDecoder = @import("traversal_standard.zig").TraversalDecoder;

pub const decodeConnectivity = @import("edgebreaker.zig").decodeConnectivity;
pub const Connectivity = @import("edgebreaker.zig").Connectivity;

pub const QuantParams = @import("attr_quant.zig").QuantParams;
pub const parseQuantParams = @import("attr_quant.zig").parseQuantParams;
pub const DecodedAttrHeader = @import("attributes.zig").DecodedAttrHeader;
pub const parseAttrHeader = @import("attributes.zig").parseAttrHeader;
pub const inversePredict = @import("predict_mesh.zig").inversePredict;
pub const TableView = @import("predict_mesh.zig").TableView;
pub const inversePredictView = @import("predict_mesh.zig").inversePredictView;
pub const buildVertexToData = @import("predict_mesh.zig").buildVertexToData;
pub const buildVertexToDataView = @import("predict_mesh.zig").buildVertexToDataView;
pub const decodeAttributes = @import("attributes.zig").decodeAttributes;
pub const PositionData = @import("attributes.zig").PositionData;

test {
    _ = @import("buffer.zig");
    _ = @import("header.zig");
    _ = @import("rans.zig"); // pulls in rans_test_encoder.zig transitively
    _ = @import("fixture_test.zig");
    _ = @import("corner_table.zig");
    _ = @import("mesh_attr_corner_table.zig");
    _ = @import("traversal_standard.zig");
    _ = @import("edgebreaker.zig");
    _ = @import("attributes.zig");
    _ = @import("attr_quant.zig");
    _ = @import("predict_mesh.zig");
    _ = @import("octahedron.zig");
}
