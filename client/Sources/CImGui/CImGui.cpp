// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "CImGui.h"
#include "imgui.h"

static_assert(sizeof(IGVertex) == sizeof(ImDrawVert), "IGVertex must match ImDrawVert");
static_assert(sizeof(ImDrawIdx) == sizeof(uint16_t), "ImDrawIdx must be 16-bit");

static ImGuiCol colorIndex(IGColor which) {
    switch (which) {
    case IGColorText: return ImGuiCol_Text;
    case IGColorTextDisabled: return ImGuiCol_TextDisabled;
    case IGColorWindow: return ImGuiCol_WindowBg;
    case IGColorChild: return ImGuiCol_ChildBg;
    case IGColorBorder: return ImGuiCol_Border;
    case IGColorFrame: return ImGuiCol_FrameBg;
    case IGColorFrameHovered: return ImGuiCol_FrameBgHovered;
    case IGColorFrameActive: return ImGuiCol_FrameBgActive;
    case IGColorButton: return ImGuiCol_Button;
    case IGColorButtonHovered: return ImGuiCol_ButtonHovered;
    case IGColorButtonActive: return ImGuiCol_ButtonActive;
    case IGColorTab: return ImGuiCol_Tab;
    case IGColorTabHovered: return ImGuiCol_TabHovered;
    case IGColorTabSelected: return ImGuiCol_TabSelected;
    case IGColorSlider: return ImGuiCol_SliderGrab;
    case IGColorSliderActive: return ImGuiCol_SliderGrabActive;
    case IGColorCheck: return ImGuiCol_CheckMark;
    case IGColorSeparator: return ImGuiCol_Separator;
    case IGColorScrollbar: return ImGuiCol_ScrollbarBg;
    case IGColorScrollbarGrab: return ImGuiCol_ScrollbarGrab;
    case IGColorHeader: return ImGuiCol_Header;
    }
    return ImGuiCol_Text;
}

extern "C" {

void igCreate(const char *fontFile, float fontPixels, float scale) {
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.LogFilename = nullptr;
    io.ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange;
    // Use a larger drag threshold because controller rays and fingertips jitter more than a mouse cursor.
    io.MouseDragThreshold = 12.0f * scale;
    io.MouseDoubleClickTime = 0.0f;
    ImFont *font = nullptr;
    if (fontFile) {
        ImFontConfig config;
        config.OversampleH = 2;
        config.OversampleV = 2;
        font = io.Fonts->AddFontFromFileTTF(fontFile, fontPixels, &config);
    }
    if (!font) {
        ImFontConfig config;
        config.SizePixels = 13.0f * (float)(int)(fontPixels / 13.0f < 1.0f ? 1.0f : fontPixels / 13.0f);
        io.Fonts->AddFontDefault(&config);
    }
    io.Fonts->Build();
    ImGui::StyleColorsDark();
    ImGui::GetStyle().ScaleAllSizes(scale);
    ImGui::GetStyle().WindowBorderSize = 0.0f;
    ImGui::GetStyle().ScrollbarSize = 28.0f * scale;
}

void igDestroy(void) { ImGui::DestroyContext(); }

void igFontAtlas(const uint8_t **pixels, int *width, int *height) {
    unsigned char *data = nullptr;
    ImGui::GetIO().Fonts->GetTexDataAsAlpha8(&data, width, height);
    *pixels = data;
}

void igStyleColor(IGColor which, float r, float g, float b, float a) {
    ImGui::GetStyle().Colors[colorIndex(which)] = ImVec4(r, g, b, a);
}

void igStyleRounding(float window, float frame, float grab) {
    ImGuiStyle &style = ImGui::GetStyle();
    style.WindowRounding = window;
    style.ChildRounding = frame;
    style.FrameRounding = frame;
    style.TabRounding = frame;
    style.GrabRounding = grab;
    style.ScrollbarRounding = grab;
}

void igStylePadding(float windowX, float windowY, float frameX, float frameY, float itemX, float itemY) {
    ImGuiStyle &style = ImGui::GetStyle();
    style.WindowPadding = ImVec2(windowX, windowY);
    style.FramePadding = ImVec2(frameX, frameY);
    style.ItemSpacing = ImVec2(itemX, itemY);
    style.ItemInnerSpacing = ImVec2(itemX * 0.75f, itemY * 0.75f);
    style.GrabMinSize = frameY * 3.0f;
}

void igNewFrame(float width, float height, float seconds) {
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(width, height);
    io.DeltaTime = seconds > 0.0f ? seconds : 1.0f / 60.0f;
    ImGui::NewFrame();
}

void igPointer(float x, float y, bool down) {
    ImGuiIO &io = ImGui::GetIO();
    if (x < 0.0f || y < 0.0f) {
        io.AddMousePosEvent(-FLT_MAX, -FLT_MAX);
        io.AddMouseButtonEvent(0, false);
    } else {
        io.AddMousePosEvent(x, y);
        io.AddMouseButtonEvent(0, down);
    }
}

void igScroll(float lines) { ImGui::GetIO().AddMouseWheelEvent(0.0f, lines); }

void igDot(float x, float y, float radius) {
    ImDrawList *over = ImGui::GetForegroundDrawList();
    over->AddCircleFilled(ImVec2(x, y), radius, IM_COL32(0, 0, 0, 140), 24);
    over->AddCircleFilled(ImVec2(x, y), radius * 0.7f, IM_COL32(255, 255, 255, 235), 24);
}

void igRender(void) { ImGui::Render(); }

int igDrawListCount(void) {
    ImDrawData *data = ImGui::GetDrawData();
    return data ? data->CmdListsCount : 0;
}

IGDrawList igDrawListAt(int list) {
    const ImDrawList *from = ImGui::GetDrawData()->CmdLists[list];
    IGDrawList out;
    out.vertices = (const IGVertex *)from->VtxBuffer.Data;
    out.indices = from->IdxBuffer.Data;
    out.vertexCount = from->VtxBuffer.Size;
    out.indexCount = from->IdxBuffer.Size;
    out.commandCount = from->CmdBuffer.Size;
    return out;
}

IGDrawCommand igDrawCommandAt(int list, int command) {
    const ImDrawCmd &from = ImGui::GetDrawData()->CmdLists[list]->CmdBuffer[command];
    IGDrawCommand out;
    out.clip[0] = from.ClipRect.x;
    out.clip[1] = from.ClipRect.y;
    out.clip[2] = from.ClipRect.z;
    out.clip[3] = from.ClipRect.w;
    // Panel widgets do not use custom ImGui draw callbacks.
    out.elementCount = from.UserCallback ? 0 : from.ElemCount;
    out.indexOffset = from.IdxOffset;
    out.vertexOffset = from.VtxOffset;
    return out;
}

void igBeginPanel(const char *name) {
    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(ImGui::GetIO().DisplaySize);
    ImGui::Begin(name, nullptr, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings
                                    | ImGuiWindowFlags_NoBringToFrontOnFocus);
}

void igEnd(void) { ImGui::End(); }

bool igBeginChild(const char *name, float width, float height, bool border) {
    return ImGui::BeginChild(name, ImVec2(width, height), border ? ImGuiChildFlags_Borders : ImGuiChildFlags_None);
}

void igEndChild(void) { ImGui::EndChild(); }
bool igBeginTabBar(const char *name) { return ImGui::BeginTabBar(name, ImGuiTabBarFlags_None); }
void igEndTabBar(void) { ImGui::EndTabBar(); }
bool igBeginTabItem(const char *label) { return ImGui::BeginTabItem(label); }
void igEndTabItem(void) { ImGui::EndTabItem(); }
void igBeginDisabled(bool disabled) { ImGui::BeginDisabled(disabled); }
void igEndDisabled(void) { ImGui::EndDisabled(); }
void igPushID(int id) { ImGui::PushID(id); }
void igPopID(void) { ImGui::PopID(); }
void igPushColor(IGColor which, float r, float g, float b, float a) { ImGui::PushStyleColor(colorIndex(which), ImVec4(r, g, b, a)); }
void igPopColor(void) { ImGui::PopStyleColor(); }
void igFontScale(float scale) { ImGui::SetWindowFontScale(scale); }

void igText(const char *text) { ImGui::TextUnformatted(text); }
void igTextDim(const char *text) {
    ImGui::PushStyleColor(ImGuiCol_Text, ImGui::GetStyle().Colors[ImGuiCol_TextDisabled]);
    ImGui::PushTextWrapPos(0.0f);
    ImGui::TextUnformatted(text);
    ImGui::PopTextWrapPos();
    ImGui::PopStyleColor();
}
void igTextWrapped(const char *text) {
    ImGui::PushTextWrapPos(0.0f);
    ImGui::TextUnformatted(text);
    ImGui::PopTextWrapPos();
}
void igSeparatorText(const char *text) { ImGui::SeparatorText(text); }
bool igButton(const char *label, float width, float height) { return ImGui::Button(label, ImVec2(width, height)); }
bool igCheckbox(const char *label, bool *value) { return ImGui::Checkbox(label, value); }
bool igRadio(const char *label, bool selected) { return ImGui::RadioButton(label, selected); }
bool igSlider(const char *label, float *value, float low, float high, const char *format) {
    return ImGui::SliderFloat(label, value, low, high, format, ImGuiSliderFlags_AlwaysClamp | ImGuiSliderFlags_NoInput);
}
bool igColor(const char *label, float *rgb) {
    return ImGui::ColorEdit3(label, rgb, ImGuiColorEditFlags_NoInputs | ImGuiColorEditFlags_PickerHueWheel);
}
void igSameLine(float spacing) { ImGui::SameLine(0.0f, spacing); }
void igSeparator(void) { ImGui::Separator(); }
void igSpacing(void) { ImGui::Spacing(); }
void igDummy(float width, float height) { ImGui::Dummy(ImVec2(width, height)); }
void igNextItemWidth(float width) { ImGui::SetNextItemWidth(width); }
void igCursorX(float x) { ImGui::SetCursorPosX(x); }
float igGetCursorX(void) { return ImGui::GetCursorPosX(); }
float igAvailableWidth(void) { return ImGui::GetContentRegionAvail().x; }
float igAvailableHeight(void) { return ImGui::GetContentRegionAvail().y; }
float igTextWidth(const char *text) { return ImGui::CalcTextSize(text).x; }
float igFrameHeight(void) { return ImGui::GetFrameHeight(); }

}
