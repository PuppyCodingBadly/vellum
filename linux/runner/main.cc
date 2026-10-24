#include "my_application.h"

#include <glib.h>

// Reads a boolean kill-switch; unset, empty, "0" and "false" are off.
static gboolean env_flag(const char* name) {
  const char* value = g_getenv(name);
  return value != nullptr && value[0] != '\0' &&
         g_ascii_strcasecmp(value, "0") != 0 &&
         g_ascii_strcasecmp(value, "false") != 0;
}

int main(int argc, char** argv) {
  // Safe mode must be applied before GTK/GDK initializes (inside
  // g_application_run), which is earlier than the Dart entrypoint runs.
  if (env_flag("VELLUM_X11")) {
    g_setenv("GDK_BACKEND", "x11", TRUE);
  }
  // LIBGL_ALWAYS_SOFTWARE is read directly by the GL stack; the Dart side logs
  // it as a startup stage marker.
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
