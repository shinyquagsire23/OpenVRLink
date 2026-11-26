// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#pragma once

/// Embedded render-model asset file with its path relative to `resources/rendermodels`.
struct ovrl_model_file {
    const char *path;
    const unsigned char *bytes;
    unsigned long long size;
};

int ovrl_pfd_model_file_count(void);
const struct ovrl_model_file *ovrl_pfd_model_file(int index);
