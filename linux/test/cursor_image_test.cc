#include <cassert>
#include <cstdio>
#include <gdk/gdkx.h>
#include <X11/extensions/Xfixes.h>

#include "../flutter_custom_cursor_plugin.cc"

static FlValue* arguments(double ratio) {
  g_autoptr(GdkPixbuf) image = gdk_pixbuf_new(GDK_COLORSPACE_RGB, true, 8, 14, 38);
  gdk_pixbuf_fill(image, 0x40802080);
  g_autofree gchar* png = nullptr;
  gsize length = 0;
  g_autoptr(GError) error = nullptr;
  assert(gdk_pixbuf_save_to_buffer(image, &png, &length, "png", &error, nullptr));
  FlValue* args = fl_value_new_map();
  fl_value_set_string_take(args, "name", fl_value_new_string("edit"));
  fl_value_set_string_take(args, "width", fl_value_new_int(14));
  fl_value_set_string_take(args, "height", fl_value_new_int(38));
  fl_value_set_string_take(args, "hotX", fl_value_new_float(6));
  fl_value_set_string_take(args, "hotY", fl_value_new_float(34));
  fl_value_set_string_take(args, "buffer", fl_value_new_uint8_list(
      reinterpret_cast<const uint8_t*>(png), length));
  if (ratio >= 0) {
    fl_value_set_string_take(args, "imagePixelRatio", fl_value_new_float(ratio));
  }
  return args;
}

static void check_cursor(FlutterCustomCursorPlugin* plugin, GdkWindow* window,
                         double ratio) {
  g_autoptr(FlValue) args = arguments(ratio);
  assert(create_custom_cursor(plugin, args) == "edit");
  GdkCursor* cursor = plugin->cache->at("edit");
  gdk_window_set_cursor(window, cursor);
  Display* display = GDK_WINDOW_XDISPLAY(window);
  XMapRaised(display, GDK_WINDOW_XID(window));
  XDefineCursor(display, GDK_WINDOW_XID(window), gdk_x11_cursor_get_xcursor(cursor));
  XWarpPointer(display, None, GDK_WINDOW_XID(window), 0, 0, 0, 0, 10, 10);
  XSync(display, False);
  XFixesCursorImage* native = XFixesGetCursorImage(display);
  assert(native != nullptr);
  const int multiplier = ratio < 0 ? 2 : 1;
  fprintf(stdout, "ratio=%.1f native=%dx%d hotspot=%d,%d\n", ratio,
          native->width, native->height, native->xhot, native->yhot);
  fflush(stdout);
  assert(native->width == 14 * multiplier);
  assert(native->height == 38 * multiplier);
  assert(native->xhot == 6 * multiplier);
  assert(native->yhot == 34 * multiplier);
  if (ratio > 0) {
    const auto pixel = native->pixels[(native->height - 1) * native->width];
    fprintf(stdout, "bottom pixel=%lx\n", pixel);
    fflush(stdout);
    assert(static_cast<uint32_t>(pixel) == 0x80204010);
  }
  XFree(native);
  assert(delete_custom_cursor(plugin, args));
}

int main(int argc, char** argv) {
  gtk_init(&argc, &argv);
  GtkWidget* widget = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_widget_show(widget);
  GdkWindow* window = gtk_widget_get_window(widget);
  assert(gdk_window_get_scale_factor(window) == 2);
  auto* plugin = FLUTTER_CUSTOM_CURSOR_PLUGIN(
      g_object_new(flutter_custom_cursor_plugin_get_type(), nullptr));
  check_cursor(plugin, window, -1);
  check_cursor(plugin, window, 2);
  g_autoptr(FlValue) invalid = arguments(0);
  assert(create_custom_cursor(plugin, invalid).empty());
  g_object_unref(plugin);
  gtk_widget_destroy(widget);
  puts("Linux cursor image tests passed");
}
