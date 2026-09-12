#include <gdk/gdkwayland.h>
#include <limits>

#include "../flutter_custom_cursor_plugin.cc"

namespace {
constexpr int kChannelBits = 8;
constexpr guint32 kInk = 0x40802080;
constexpr gint64 kPointerTimeoutUs = 10 * G_USEC_PER_SEC;
constexpr guint kPollUs = 1000;
constexpr int kDbusTimeoutMs = 5000;
constexpr char kDisplayName[] = "cursor-test-wayland";
constexpr double kPointerReset = -4096;
constexpr double kPointerPosition = 100;
constexpr char kRemoteDesktop[] = "org.gnome.Mutter.RemoteDesktop";
constexpr char kRemotePath[] = "/org/gnome/Mutter/RemoteDesktop";
constexpr char kSessionInterface[] = "org.gnome.Mutter.RemoteDesktop.Session";

struct CursorCase {
  string name;
  int width, height, ink_width;
  double ratio, hot_x, hot_y;
  int logical_x, logical_y;
  bool legacy = false;
};

struct TestContext {
  FlutterCustomCursorPlugin* plugin;
  GdkWindow* window;
  const char* output;
};

static FlValue* arguments(const CursorCase& sample) {
  g_autoptr(GdkPixbuf) image = gdk_pixbuf_new(
      GDK_COLORSPACE_RGB, true, kChannelBits, sample.width, sample.height);
  gdk_pixbuf_fill(image, 0);
  g_autoptr(GdkPixbuf) ink = gdk_pixbuf_new_subpixbuf(
      image, 0, 0, sample.ink_width, sample.height);
  gdk_pixbuf_fill(ink, kInk);
  g_autofree gchar* png = nullptr;
  gsize length = 0;
  g_autoptr(GError) error = nullptr;
  g_assert_true(gdk_pixbuf_save_to_buffer(image, &png, &length, "png", &error, nullptr));
  g_assert_no_error(error);
  FlValue* args = fl_value_new_map();
  fl_value_set_string_take(args, "name", fl_value_new_string("wayland-test"));
  fl_value_set_string_take(args, "width", fl_value_new_int(sample.width));
  fl_value_set_string_take(args, "height", fl_value_new_int(sample.height));
  fl_value_set_string_take(args, "hotX", fl_value_new_float(sample.hot_x));
  fl_value_set_string_take(args, "hotY", fl_value_new_float(sample.hot_y));
  fl_value_set_string_take(args, "buffer", fl_value_new_uint8_list(
      reinterpret_cast<const uint8_t*>(png), length));
  if (!sample.legacy) {
    fl_value_set_string_take(args, "imagePixelRatio", fl_value_new_float(sample.ratio));
  }
  return args;
}

static void drain_events() {
  gdk_display_sync(gdk_display_get_default());
  while (g_main_context_iteration(nullptr, false)) {}
}

static void check_cursor(const TestContext& context, const CursorCase& sample) {
  fprintf(stderr, "CURSOR_BEGIN %s %d %d %.0f %d %d\n", sample.name.c_str(),
          sample.width, sample.height, sample.ratio, sample.logical_x, sample.logical_y);
  g_autoptr(FlValue) args = arguments(sample);
  const auto path = string(context.output) + "/" + sample.name + ".png";
  FlValue* buffer = fl_value_lookup_string(args, "buffer");
  g_autoptr(GError) error = nullptr;
  g_assert_true(g_file_set_contents(path.c_str(),
      reinterpret_cast<const gchar*>(fl_value_get_uint8_list(buffer)),
      fl_value_get_length(buffer), &error));
  g_assert_no_error(error);
  g_assert_true(create_custom_cursor(context.plugin, args) == "wayland-test");
  gpointer alive = context.plugin->cache->at("wayland-test");
  g_object_add_weak_pointer(G_OBJECT(alive), &alive);
  gdk_window_set_cursor(context.window, GDK_CURSOR(alive));
  drain_events();
  fprintf(stderr, "CURSOR_END %s\n", sample.name.c_str());
  g_assert_true(delete_custom_cursor(context.plugin, args));
  g_assert_nonnull(alive);  // The active GDK window still owns this cursor.
  g_assert_false(delete_custom_cursor(context.plugin, args));
  gdk_window_set_cursor(context.window, nullptr);
  drain_events();
  g_assert_null(alive);
  g_assert_true(context.plugin->cache->empty());
}

static int check_shapes(const TestContext& context) {
  const CursorCase shapes[] = {
      {"tall", 6, 6, 3, 1, 2, 5, 2, 5},
      {"wide", 6, 3, 6, 1, 5, 2, 5, 2},
      {"thin-vertical", 12, 12, 1, 1, 0, 11, 0, 11},
      {"thin-horizontal", 12, 1, 12, 1, 11, 0, 11, 0},
      {"one-pixel", 1, 1, 1, 1, 0, 0, 0, 0},
  };
  int count = 0;
  for (const int scale : {1, 2, 3}) {
    for (const auto& shape : shapes) {
      const CursorCase sample{shape.name + "-" + std::to_string(scale),
          shape.width * scale, shape.height * scale, shape.ink_width * scale,
          static_cast<double>(scale), shape.hot_x * scale, shape.hot_y * scale,
          shape.logical_x, shape.logical_y};
      check_cursor(context, sample);
      ++count;
    }
  }
  const CursorCase extras[] = {
      {"legacy", 6, 6, 3, 1, 2, 5, 2, 5, true},
      {"rounded-hotspot", 12, 12, 6, 2, 3.5, 9.5, 2, 5},
      {"clamped-hotspot", 12, 12, 6, 2, 11.5, 11.5, 5, 5},
  };
  for (const auto& sample : extras) {
    check_cursor(context, sample);
    ++count;
  }
  return count;
}

static void check_rejected(FlutterCustomCursorPlugin* plugin, FlValue* args,
                           const char* warning) {
  if (warning != nullptr) g_test_expect_message(nullptr, G_LOG_LEVEL_WARNING, warning);
  g_assert_true(create_custom_cursor(plugin, args).empty());
  g_test_assert_expected_messages();
  g_assert_true(plugin->cache->empty());
}

static int check_invalid(FlutterCustomCursorPlugin* plugin) {
  constexpr double kNan = std::numeric_limits<double>::quiet_NaN();
  constexpr double kInfinity = std::numeric_limits<double>::infinity();
  const CursorCase valid{"invalid", 12, 12, 6, 2, 4, 10, 2, 5};
  int count = 0;
  for (const double ratio : {0.0, -1.0, 1.25, 13.0, kNan, kInfinity}) {
    g_autoptr(FlValue) args = arguments(valid);
    fl_value_set_string_take(args, "imagePixelRatio", fl_value_new_float(ratio));
    check_rejected(plugin, args, "Invalid cursor imagePixelRatio or hotspot");
    ++count;
  }
  for (const char* key : {"hotX", "hotY"}) {
    for (const double hotspot : {-1.0, 12.0, kNan, kInfinity}) {
      g_autoptr(FlValue) args = arguments(valid);
      fl_value_set_string_take(args, key, fl_value_new_float(hotspot));
      check_rejected(plugin, args, "Invalid cursor imagePixelRatio or hotspot");
      ++count;
    }
  }
  for (const char* axis : {"width", "height"}) {
    const CursorCase uneven{"uneven", strcmp(axis, "width") == 0 ? 13 : 12,
        strcmp(axis, "height") == 0 ? 13 : 12, 6, 2, 4, 10, 2, 5};
    g_autoptr(FlValue) args = arguments(uneven);
    check_rejected(plugin, args, "Cursor dimensions must be multiples of imagePixelRatio");
    ++count;
  }
  g_autoptr(FlValue) integer_ratio = arguments(valid);
  fl_value_set_string_take(integer_ratio, "imagePixelRatio", fl_value_new_int(2));
  check_rejected(plugin, integer_ratio, "Cursor imagePixelRatio must be a double");
  constexpr uint8_t kInvalidPng[] = {0};
  g_autoptr(FlValue) invalid_png = arguments(valid);
  fl_value_set_string_take(invalid_png, "buffer",
      fl_value_new_uint8_list(kInvalidPng, sizeof(kInvalidPng)));
  check_rejected(plugin, invalid_png, nullptr);
  return count + 2;
}

static string start_pointer(GDBusConnection* connection) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) result = g_dbus_connection_call_sync(connection,
      kRemoteDesktop, kRemotePath, kRemoteDesktop, "CreateSession", nullptr,
      G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, kDbusTimeoutMs, nullptr, &error);
  g_assert_no_error(error);
  const gchar* path = nullptr;
  g_variant_get(result, "(&o)", &path);
  const string session(path);
  g_autoptr(GVariant) started = g_dbus_connection_call_sync(connection,
      kRemoteDesktop, session.c_str(), kSessionInterface, "Start", nullptr,
      nullptr, G_DBUS_CALL_FLAGS_NONE, kDbusTimeoutMs, nullptr, &error);
  g_assert_no_error(error);
  return session;
}

static void move_pointer(GDBusConnection* connection, const string& session,
                         double distance) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) result = g_dbus_connection_call_sync(connection,
      kRemoteDesktop, session.c_str(), kSessionInterface, "NotifyPointerMotionRelative",
      g_variant_new("(dd)", distance, distance), nullptr, G_DBUS_CALL_FLAGS_NONE,
      kDbusTimeoutMs, nullptr, &error);
  g_assert_no_error(error);
}

static GtkWidget* prepare_window(GDBusConnection* connection, const string& session) {
  GtkWidget* widget = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(widget), "Wayland cursor integration test");
  gtk_window_fullscreen(GTK_WINDOW(widget));
  gtk_widget_show(widget);
  gtk_window_present(GTK_WINDOW(widget));
  const gint64 deadline = g_get_monotonic_time() + kPointerTimeoutUs;
  while (g_get_monotonic_time() < deadline) {
    drain_events();
    move_pointer(connection, session, kPointerReset);
    drain_events();
    move_pointer(connection, session, kPointerPosition);
    drain_events();
    GdkDevice* pointer = gdk_seat_get_pointer(gdk_display_get_default_seat(
        gdk_display_get_default()));
    if (pointer != nullptr && gdk_device_get_window_at_position(pointer, nullptr,
        nullptr) == gtk_widget_get_window(widget)) return widget;
    g_usleep(kPollUs);
  }
  g_error("The virtual pointer did not enter the private test window");
  return nullptr;
}
}  // namespace

int main(int argc, char** argv) {
  g_test_init(&argc, &argv, nullptr);
  g_assert_cmpint(argc, ==, 2);
  const string runtime = string(argv[1]) + "/runtime";
  g_assert_cmpstr(g_getenv("XDG_RUNTIME_DIR"), ==, runtime.c_str());
  g_assert_cmpstr(g_getenv("WAYLAND_DISPLAY"), ==, kDisplayName);
  gtk_init(&argc, &argv);
  g_assert_true(GDK_IS_WAYLAND_DISPLAY(gdk_display_get_default()));
  g_autoptr(GError) error = nullptr;
  g_autoptr(GDBusConnection) connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  g_assert_no_error(error);
  const auto session = start_pointer(connection);
  GtkWidget* widget = prepare_window(connection, session);
  auto* plugin = FLUTTER_CUSTOM_CURSOR_PLUGIN(
      g_object_new(flutter_custom_cursor_plugin_get_type(), nullptr));
  const TestContext context{plugin, gtk_widget_get_window(widget), argv[1]};
  const int accepted = check_shapes(context);
  const int rejected = check_invalid(plugin);
  g_object_unref(plugin);
  // Remove the virtual input device while its focused window is still alive.
  g_autoptr(GVariant) stopped = g_dbus_connection_call_sync(connection,
      kRemoteDesktop, session.c_str(), kSessionInterface, "Stop", nullptr,
      nullptr, G_DBUS_CALL_FLAGS_NONE, kDbusTimeoutMs, nullptr, &error);
  g_assert_no_error(error);
  drain_events();
  gtk_widget_destroy(widget);
  drain_events();
  printf("NATIVE_DONE accepted=%d rejected=%d\n", accepted, rejected);
}
