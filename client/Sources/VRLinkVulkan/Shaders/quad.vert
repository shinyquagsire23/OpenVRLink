// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Vulkan vertex shader for VulkanXRGraphics. Input vertices come from VRLinkCore's QuadMesh already
// projected into clip space, with UVs pre-multiplied by forward eye distance (`ahead`); see QuadMesh.swift.
#version 450

layout(location = 0) in vec4 position;
layout(location = 1) in vec2 uv;
layout(location = 2) in vec2 alphaUV;
layout(location = 3) in vec2 tile;
layout(location = 4) in float ahead;

layout(location = 0) out vec2 outUV;
layout(location = 1) out vec2 outAlphaUV;
layout(location = 2) out vec2 outTile;
layout(location = 3) out float outAhead;

void main() {
    gl_Position = position;
    outUV = uv;
    outAlphaUV = alphaUV;
    outTile = tile;
    outAhead = ahead;
}
