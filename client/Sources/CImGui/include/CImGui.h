// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// C wrapper around the Dear ImGui APIs used by VRLinkPanel.
//
// While Swift can import imgui.h directly via C++ interoperability, enabling C++ interop on a Swift target
// requires every downstream target to enable it as well, which would force the app shells and their C headers
// (OpenXR, Vulkan, Android NDK) to compile in C++ mode. Wrapping ImGui in plain C isolates C++ to this target.

#ifndef CIMGUI_H
#define CIMGUI_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Vertex layout matching ImDrawVert, with pixel position, UV coordinates, and packed RGBA color (red in the low byte).
typedef struct IGVertex {
    float x, y, u, v;
    uint32_t color;
} IGVertex;

typedef struct IGDrawList {
    const IGVertex *vertices;
    const uint16_t *indices;
    int vertexCount, indexCount, commandCount;
} IGDrawList;

typedef struct IGDrawCommand {
    /// Clip rectangle in pixels as (left, top, right, bottom).
    float clip[4];
    unsigned int elementCount, indexOffset, vertexOffset;
} IGDrawCommand;

/// Style colors configured by the panel (mapped to ImGuiCol_ indices in CImGui.cpp).
typedef enum IGColor {
    IGColorText, IGColorTextDisabled, IGColorWindow, IGColorChild, IGColorBorder, IGColorFrame, IGColorFrameHovered,
    IGColorFrameActive, IGColorButton, IGColorButtonHovered, IGColorButtonActive, IGColorTab, IGColorTabHovered,
    IGColorTabSelected, IGColorSlider, IGColorSliderActive, IGColorCheck, IGColorSeparator, IGColorScrollbar,
    IGColorScrollbarGrab, IGColorHeader,
} IGColor;

/// Creates the ImGui context. Pass NULL (or an unreadable path) for `fontFile` to use the built-in bitmap font;
/// `scale` multiplies all style sizes.
void igCreate(const char *fontFile, float fontPixels, float scale);
void igDestroy(void);
/// Returns the 8-bit alpha font atlas; untextured shapes sample its solid white texel.
void igFontAtlas(const uint8_t **pixels, int *width, int *height);
void igStyleColor(IGColor which, float r, float g, float b, float a);
void igStyleRounding(float window, float frame, float grab);
void igStylePadding(float windowX, float windowY, float frameX, float frameY, float itemX, float itemY);

void igNewFrame(float width, float height, float seconds);
/// Updates pointer position in pixels (negative when inactive) and button state.
void igPointer(float x, float y, bool down);
void igScroll(float lines);
/// Draws a foreground pointer cursor dot at `(x, y)` in pixels.
void igDot(float x, float y, float radius);
void igRender(void);
int igDrawListCount(void);
IGDrawList igDrawListAt(int list);
IGDrawCommand igDrawCommandAt(int list, int command);

/// Begins a borderless fullscreen ImGui window.
void igBeginPanel(const char *name);
void igEnd(void);
bool igBeginChild(const char *name, float width, float height, bool border);
void igEndChild(void);
bool igBeginTabBar(const char *name);
void igEndTabBar(void);
bool igBeginTabItem(const char *label);
void igEndTabItem(void);
void igBeginDisabled(bool disabled);
void igEndDisabled(void);
void igPushID(int id);
void igPopID(void);
void igPushColor(IGColor which, float r, float g, float b, float a);
void igPopColor(void);
void igFontScale(float scale);

void igText(const char *text);
void igTextDim(const char *text);
void igTextWrapped(const char *text);
void igSeparatorText(const char *text);
bool igButton(const char *label, float width, float height);
bool igCheckbox(const char *label, bool *value);
bool igRadio(const char *label, bool selected);
bool igSlider(const char *label, float *value, float low, float high, const char *format);
bool igColor(const char *label, float *rgb);
void igSameLine(float spacing);
void igSeparator(void);
void igSpacing(void);
void igDummy(float width, float height);
void igNextItemWidth(float width);
void igCursorX(float x);
float igGetCursorX(void);
float igAvailableWidth(void);
float igAvailableHeight(void);
float igTextWidth(const char *text);
float igFrameHeight(void);

#ifdef __cplusplus
}
#endif

#endif
