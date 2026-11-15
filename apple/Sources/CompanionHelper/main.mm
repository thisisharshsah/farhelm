// Chromium's helper processes (renderer, GPU, network, plugins), bundled
// by build.sh as "Companion Helper*.app" inside Companion.app. When one
// cannot start it says why on stderr (run Companion from a terminal to
// see it), since Chromium only reports that the helper exited.
#if __has_include("include/cef_app.h")
#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string>
#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

static std::string FrameworkPath() {
  char exe[PATH_MAX];
  uint32_t size = sizeof(exe);
  if (_NSGetExecutablePath(exe, &size) != 0) return "";
  char real[PATH_MAX];
  if (!realpath(exe, real)) return "";
  return std::string(dirname(real)) +
         "/../../../Chromium Embedded Framework.framework/Chromium Embedded Framework";
}

int main(int argc, char* argv[]) {
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    std::string path = FrameworkPath();
    void* handle = dlopen(path.c_str(), RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
    fprintf(stderr, "Companion Helper: Chromium's framework did not load from %s: %s\n", path.c_str(),
            handle ? "it loads directly, so CEF's loader refused it" : dlerror());
    return 1;
  }
  CefMainArgs main_args(argc, argv);
  int code = CefExecuteProcess(main_args, nullptr, nullptr);
  if (code != 0) fprintf(stderr, "Companion Helper: Chromium's process ended with %d\n", code);
  return code;
}
#else
#include <stdio.h>
int main(int argc, char* argv[]) {
  fprintf(stderr, "Companion Helper: built without Chromium.\n");
  return 1;
}
#endif
