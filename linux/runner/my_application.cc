#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <keybinder.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  FlMethodChannel* hotkey_channel;
};

typedef struct {
  MyApplication* self;
  gchar* method;
} HotkeyInvokeData;

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static void hotkey_response_cb(GObject* object, GAsyncResult* result, gpointer user_data) {
  g_autoptr(GError) error = nullptr;
  FlMethodChannel* channel = FL_METHOD_CHANNEL(object);
  g_autoptr(FlMethodResponse) response =
      fl_method_channel_invoke_method_finish(channel, result, &error);
  if (response == nullptr) {
    g_warning("Flutter hotkey method failed: %s", error ? error->message : "unknown");
    return;
  }

  if (FL_IS_METHOD_SUCCESS_RESPONSE(response)) {
    g_message("Flutter hotkey method succeeded.");
  } else if (FL_IS_METHOD_ERROR_RESPONSE(response)) {
    const gchar* code = fl_method_error_response_get_code(FL_METHOD_ERROR_RESPONSE(response));
    const gchar* message = fl_method_error_response_get_message(FL_METHOD_ERROR_RESPONSE(response));
    g_warning("Flutter hotkey method error: %s %s", code ? code : "", message ? message : "");
  } else if (FL_IS_METHOD_NOT_IMPLEMENTED_RESPONSE(response)) {
    g_warning("Flutter hotkey method not implemented.");
  } else {
    g_warning("Flutter hotkey method response was not successful.");
  }
}

static gboolean invoke_hotkey_method_idle(gpointer user_data) {
  HotkeyInvokeData* data = (HotkeyInvokeData*)user_data;
  MyApplication* self = data->self;
  if (self->hotkey_channel == nullptr) {
    g_warning("Hotkey channel not ready (idle invoke). Dropping %s.", data->method);
  } else {
    g_autoptr(FlValue) args = fl_value_new_null();
    g_message("Invoking Flutter hotkey method: %s", data->method);
    fl_method_channel_invoke_method(
        self->hotkey_channel,
        data->method,
        args,
        nullptr,
        hotkey_response_cb,
        nullptr);
  }

  g_object_unref(self);
  g_free(data->method);
  g_free(data);
  return G_SOURCE_REMOVE;
}

static void invoke_hotkey_method(MyApplication* self, const gchar* method) {
  if (self->hotkey_channel == nullptr) {
    g_warning("Hotkey channel not ready. Dropping %s.", method);
    return;
  }

  HotkeyInvokeData* data = g_new0(HotkeyInvokeData, 1);
  data->self = MY_APPLICATION(g_object_ref(self));
  data->method = g_strdup(method);
  g_idle_add(invoke_hotkey_method_idle, data);
}

static void hotkey_handler(const gchar* keystring, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_message("Global hotkey fired: %s", keystring);
  if (g_strcmp0(keystring, "<Ctrl><Shift>M") == 0 ||
      g_strcmp0(keystring, "<Ctrl><Alt>M") == 0) {
    invoke_hotkey_method(self, "minimize");
  } else if (g_strcmp0(keystring, "<Ctrl><Shift>T") == 0 ||
             g_strcmp0(keystring, "<Ctrl><Alt>T") == 0 ||
             g_strcmp0(keystring, "<Ctrl><Alt>Y") == 0) {
    invoke_hotkey_method(self, "toggleAlwaysOnTop");
  } else {
    g_warning("Unhandled hotkey: %s", keystring);
  }
}

static void bind_global_hotkeys(MyApplication* self) {
  GdkDisplay* display = gdk_display_get_default();
#ifdef GDK_WINDOWING_X11
  if (display != nullptr && GDK_IS_X11_DISPLAY(display)) {
    keybinder_init();
    keybinder_set_use_cooked_accelerators(TRUE);
    g_message("GDK display: %s", gdk_display_get_name(display));
    if (!keybinder_supported()) {
      g_warning("Global hotkeys are not supported by the current X11 setup.");
      return;
    }
    const gboolean bind_min = keybinder_bind("<Ctrl><Shift>M", hotkey_handler, self);
    const gboolean bind_top = keybinder_bind("<Ctrl><Shift>T", hotkey_handler, self);
    const gboolean bind_min_alt = keybinder_bind("<Ctrl><Alt>M", hotkey_handler, self);
    gboolean bind_top_alt = keybinder_bind("<Ctrl><Alt>T", hotkey_handler, self);
    if (!bind_top_alt) {
      bind_top_alt = keybinder_bind("<Ctrl><Alt>Y", hotkey_handler, self);
      if (bind_top_alt) {
        g_warning("Ctrl+Alt+T is taken; using Ctrl+Alt+Y for always-on-top.");
      }
    }
    g_message("Global hotkey bind Ctrl+Shift+M: %s", bind_min ? "ok" : "failed");
    g_message("Global hotkey bind Ctrl+Shift+T: %s", bind_top ? "ok" : "failed");
    g_message("Global hotkey bind Ctrl+Alt+M: %s", bind_min_alt ? "ok" : "failed");
    g_message("Global hotkey bind Ctrl+Alt+T: %s", bind_top_alt ? "ok" : "failed");
  } else {
    g_warning("Global hotkeys require X11; skipped binding on Wayland.");
  }
#else
  (void)display;
  g_warning("Global hotkeys require X11; keybinder not available.");
#endif
}

static void unbind_global_hotkeys() {
  keybinder_unbind("<Ctrl><Shift>M", hotkey_handler);
  keybinder_unbind("<Ctrl><Shift>T", hotkey_handler);
  keybinder_unbind("<Ctrl><Alt>M", hotkey_handler);
  keybinder_unbind("<Ctrl><Alt>T", hotkey_handler);
  keybinder_unbind("<Ctrl><Alt>Y", hotkey_handler);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Linia");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Linia");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  const gchar* assets_path = fl_dart_project_get_assets_path(project);
  if (assets_path != nullptr) {
    g_autofree gchar* icon_path =
        g_build_filename(assets_path, "assets", "Linia.png", nullptr);

    g_autoptr(GError) icon_error = nullptr;
    if (!gtk_window_set_default_icon_from_file(icon_path, &icon_error)) {
      g_warning("Failed to set default icon: %s",
                icon_error ? icon_error->message : "unknown");
    }

    icon_error = nullptr;
    if (!gtk_window_set_icon_from_file(window, icon_path, &icon_error)) {
      g_warning("Failed to set window icon: %s",
                icon_error ? icon_error->message : "unknown");
    }

    gtk_window_set_icon_name(window, "linia");
  }

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  FlEngine* engine = fl_view_get_engine(view);
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->hotkey_channel = fl_method_channel_new(
      messenger, "linia/global_hotkey", FL_METHOD_CODEC(codec));
  g_message("Hotkey channel ready.");

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  bind_global_hotkeys(self);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.
  unbind_global_hotkeys();

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  self->window = nullptr;
  self->hotkey_channel = nullptr;
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
