// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "RepoVersion.h"

// The repository's version.json, compiled in (C23 `#embed`, which the compiler
// tracks as a dependency, so editing version.json rebuilds this file).
#pragma clang diagnostic ignored "-Wc23-extensions"
static const char text[] = {
#embed "../../../version.json"
    , 0
};

const char *ovrl_version_json(void) { return text; }
