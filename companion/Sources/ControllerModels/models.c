// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Embedded Play For Dream MR controller render models (pfd/, extracted from Play For Dream's "MR SteamLink
// Driver" 1.0.1.0 and redistributed with permission).
#include "ControllerModels.h"

#pragma clang diagnostic ignored "-Wc23-extensions"
static const unsigned char file0[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_joystick.tga"
};
static const unsigned char file1[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left.json"
};
static const unsigned char file2[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left.mtl"
};
static const unsigned char file3[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left.obj"
};
static const unsigned char file4[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left.png"
};
static const unsigned char file5[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left_body.mtl"
};
static const unsigned char file6[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left_body.obj"
};
static const unsigned char file7[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left_grip.mtl"
};
static const unsigned char file8[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left_grip.obj"
};
static const unsigned char file9[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left_home.mtl"
};
static const unsigned char file10[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left_home.obj"
};
static const unsigned char file11[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left_joystick.mtl"
};
static const unsigned char file12[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left_joystick.obj"
};
static const unsigned char file13[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left_trigger.mtl"
};
static const unsigned char file14[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left_trigger.obj"
};
static const unsigned char file15[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left_xbutton.mtl"
};
static const unsigned char file16[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left_xbutton.obj"
};
static const unsigned char file17[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left_ybutton.mtl"
};
static const unsigned char file18[] = {
#embed "pfd/pfd_mr_controller_left/pfd_mr_controller_left_ybutton.obj"
};
static const unsigned char file19[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_joystick.tga"
};
static const unsigned char file20[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right.json"
};
static const unsigned char file21[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right.mtl"
};
static const unsigned char file22[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right.obj"
};
static const unsigned char file23[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right.png"
};
static const unsigned char file24[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right_abutton.mtl"
};
static const unsigned char file25[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right_abutton.obj"
};
static const unsigned char file26[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right_bbutton.mtl"
};
static const unsigned char file27[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right_bbutton.obj"
};
static const unsigned char file28[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right_body.mtl"
};
static const unsigned char file29[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right_body.obj"
};
static const unsigned char file30[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right_grip.mtl"
};
static const unsigned char file31[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right_grip.obj"
};
static const unsigned char file32[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right_home.mtl"
};
static const unsigned char file33[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right_home.obj"
};
static const unsigned char file34[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right_joystick.mtl"
};
static const unsigned char file35[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right_joystick.obj"
};
static const unsigned char file36[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right_trigger.mtl"
};
static const unsigned char file37[] = {
#embed "pfd/pfd_mr_controller_right/pfd_mr_controller_right_trigger.obj"
};

static const struct ovrl_model_file files[] = {
    {"pfd_mr_controller_left/pfd_mr_controller_joystick.tga", file0, sizeof file0},
    {"pfd_mr_controller_left/pfd_mr_controller_left.json", file1, sizeof file1},
    {"pfd_mr_controller_left/pfd_mr_controller_left.mtl", file2, sizeof file2},
    {"pfd_mr_controller_left/pfd_mr_controller_left.obj", file3, sizeof file3},
    {"pfd_mr_controller_left/pfd_mr_controller_left.png", file4, sizeof file4},
    {"pfd_mr_controller_left/pfd_mr_controller_left_body.mtl", file5, sizeof file5},
    {"pfd_mr_controller_left/pfd_mr_controller_left_body.obj", file6, sizeof file6},
    {"pfd_mr_controller_left/pfd_mr_controller_left_grip.mtl", file7, sizeof file7},
    {"pfd_mr_controller_left/pfd_mr_controller_left_grip.obj", file8, sizeof file8},
    {"pfd_mr_controller_left/pfd_mr_controller_left_home.mtl", file9, sizeof file9},
    {"pfd_mr_controller_left/pfd_mr_controller_left_home.obj", file10, sizeof file10},
    {"pfd_mr_controller_left/pfd_mr_controller_left_joystick.mtl", file11, sizeof file11},
    {"pfd_mr_controller_left/pfd_mr_controller_left_joystick.obj", file12, sizeof file12},
    {"pfd_mr_controller_left/pfd_mr_controller_left_trigger.mtl", file13, sizeof file13},
    {"pfd_mr_controller_left/pfd_mr_controller_left_trigger.obj", file14, sizeof file14},
    {"pfd_mr_controller_left/pfd_mr_controller_left_xbutton.mtl", file15, sizeof file15},
    {"pfd_mr_controller_left/pfd_mr_controller_left_xbutton.obj", file16, sizeof file16},
    {"pfd_mr_controller_left/pfd_mr_controller_left_ybutton.mtl", file17, sizeof file17},
    {"pfd_mr_controller_left/pfd_mr_controller_left_ybutton.obj", file18, sizeof file18},
    {"pfd_mr_controller_right/pfd_mr_controller_joystick.tga", file19, sizeof file19},
    {"pfd_mr_controller_right/pfd_mr_controller_right.json", file20, sizeof file20},
    {"pfd_mr_controller_right/pfd_mr_controller_right.mtl", file21, sizeof file21},
    {"pfd_mr_controller_right/pfd_mr_controller_right.obj", file22, sizeof file22},
    {"pfd_mr_controller_right/pfd_mr_controller_right.png", file23, sizeof file23},
    {"pfd_mr_controller_right/pfd_mr_controller_right_abutton.mtl", file24, sizeof file24},
    {"pfd_mr_controller_right/pfd_mr_controller_right_abutton.obj", file25, sizeof file25},
    {"pfd_mr_controller_right/pfd_mr_controller_right_bbutton.mtl", file26, sizeof file26},
    {"pfd_mr_controller_right/pfd_mr_controller_right_bbutton.obj", file27, sizeof file27},
    {"pfd_mr_controller_right/pfd_mr_controller_right_body.mtl", file28, sizeof file28},
    {"pfd_mr_controller_right/pfd_mr_controller_right_body.obj", file29, sizeof file29},
    {"pfd_mr_controller_right/pfd_mr_controller_right_grip.mtl", file30, sizeof file30},
    {"pfd_mr_controller_right/pfd_mr_controller_right_grip.obj", file31, sizeof file31},
    {"pfd_mr_controller_right/pfd_mr_controller_right_home.mtl", file32, sizeof file32},
    {"pfd_mr_controller_right/pfd_mr_controller_right_home.obj", file33, sizeof file33},
    {"pfd_mr_controller_right/pfd_mr_controller_right_joystick.mtl", file34, sizeof file34},
    {"pfd_mr_controller_right/pfd_mr_controller_right_joystick.obj", file35, sizeof file35},
    {"pfd_mr_controller_right/pfd_mr_controller_right_trigger.mtl", file36, sizeof file36},
    {"pfd_mr_controller_right/pfd_mr_controller_right_trigger.obj", file37, sizeof file37},
};

int ovrl_pfd_model_file_count(void) { return (int)(sizeof files / sizeof files[0]); }
const struct ovrl_model_file *ovrl_pfd_model_file(int index) { return &files[index]; }
