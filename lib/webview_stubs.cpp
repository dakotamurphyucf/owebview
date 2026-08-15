/* OCaml 5 bindings for webview 0.12.
 *
 * The OCaml handle is a custom block pointing at managed_webview. Native state
 * remains alive until explicit platform teardown has completed and all
 * registered OCaml roots have been released.
 */

#include <atomic>
#include <cctype>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <new>
#include <stdexcept>
#include <string>
#include <thread>
#include <type_traits>
#include <unordered_map>
#include <vector>

#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include "webview.h"

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <Block.h>
#include <dispatch/dispatch.h>
#include <objc/message.h>
#include <objc/objc.h>
#include <objc/runtime.h>
#elif defined(__linux__)
#include <gtk/gtk.h>
#elif defined(_WIN32)
#include <windows.h>
#include <shellapi.h>
#endif

namespace {

constexpr int OWV_ERROR_CLOSED = -1000;
constexpr int OWV_ERROR_CLOSING = -1001;
constexpr int OWV_ERROR_WRONG_THREAD = -1002;
constexpr int OWV_ERROR_INVALID_LIFECYCLE = -1003;
constexpr int OWV_ERROR_CPP_EXCEPTION = -1004;
constexpr int OWV_ERROR_OUT_OF_MEMORY = -1005;

enum class lifecycle { created, running, stopped, closing, closed };

struct managed_webview;
struct dialog_state;

struct binding_state {
  managed_webview *owner{};
  value closure{Val_unit};
  bool root_registered{false};
  bool include_url{false};
  std::atomic_bool active{true};
  std::string name;
};

struct dispatch_state {
  managed_webview *owner{};
  value closure{Val_unit};
  value handle{Val_unit};
  bool closure_root_registered{false};
  bool handle_root_registered{false};
  std::atomic_bool executing{false};
  std::atomic_bool completed{false};
};

struct dialog_state {
  managed_webview *owner{};
  value completion{Val_unit};
  value handle{Val_unit};
  bool completion_root_registered{false};
  bool handle_root_registered{false};
  std::atomic_uint references{1};
  std::atomic_bool completed{false};
  std::atomic_bool presented{false};
  std::atomic_bool native_finished{false};
  std::atomic_bool cancel_requested{false};
  std::atomic_bool close_after_completion{false};
  std::atomic_bool close_scheduled{false};
  int kind{};
  std::string title;
  std::string detail;
#if defined(__APPLE__)
  id parent{};
  id presenter{};
#endif
};

struct managed_webview {
  std::mutex mutex;
  std::condition_variable idle;
  webview_t native{};
  lifecycle state{lifecycle::created};
  std::thread::id owner_thread;
  unsigned active_calls{0};
  bool native_window_closed{false};
  value close_closure{Val_unit};
  bool close_root_registered{false};
  value close_request_closure{Val_unit};
  bool close_request_root_registered{false};
  value navigation_closure{Val_unit};
  bool navigation_root_registered{false};
  value theme_closure{Val_unit};
  bool theme_root_registered{false};
#if defined(__APPLE__)
  id close_observer{};
  id fullscreen_button{};
  id navigation_delegate{};
  id theme_observer{};
  dialog_state *pending_dialog{};
#elif defined(__linux__)
  gulong close_signal{};
  gulong close_request_signal{};
  gulong navigation_signal{};
  gulong theme_signal{};
#endif
  std::unordered_map<std::string, binding_state *> active_bindings;
  std::vector<binding_state *> all_bindings;
  std::vector<dispatch_state *> all_dispatches;
};

static managed_webview *&State_val(value v) {
  return *reinterpret_cast<managed_webview **>(Data_custom_val(v));
}

static const char *wv_strerror(int code) {
  switch (code) {
    case WEBVIEW_ERROR_MISSING_DEPENDENCY:
      return "missing dependency";
    case WEBVIEW_ERROR_CANCELED:
      return "operation canceled";
    case WEBVIEW_ERROR_INVALID_STATE:
      return "invalid state";
    case WEBVIEW_ERROR_INVALID_ARGUMENT:
      return "invalid argument";
    case WEBVIEW_ERROR_UNSPECIFIED:
      return "unspecified error";
    case WEBVIEW_ERROR_OK:
      return "ok";
    case WEBVIEW_ERROR_DUPLICATE:
      return "already exists";
    case WEBVIEW_ERROR_NOT_FOUND:
      return "not found";
    case OWV_ERROR_CLOSED:
      return "webview is closed";
    case OWV_ERROR_CLOSING:
      return "webview is closing";
    case OWV_ERROR_WRONG_THREAD:
      return "operation must run on the owning UI thread";
    case OWV_ERROR_INVALID_LIFECYCLE:
      return "operation is invalid in the current lifecycle state";
    case OWV_ERROR_CPP_EXCEPTION:
      return "C++ exception";
    case OWV_ERROR_OUT_OF_MEMORY:
      return "out of memory";
    default:
      return "unknown error";
  }
}

[[noreturn]] static void raise_error(const char *operation, int code,
                                     const char *message = nullptr) {
  CAMLparam0();
  CAMLlocal1(payload);
  const value *exception = caml_named_value("owebview.native_error");
  if (exception == nullptr) {
    caml_failwith("owebview native exception is not registered");
  }
  payload = caml_alloc_tuple(3);
  Store_field(payload, 0, caml_copy_string(operation));
  Store_field(payload, 1, Val_int(code));
  Store_field(payload, 2,
              caml_copy_string(message == nullptr ? wv_strerror(code) : message));
  caml_raise_with_arg(*exception, payload);
  CAMLnoreturn;
  std::abort();
}

static void check_error(const char *operation, webview_error_t error) {
  if (error != WEBVIEW_ERROR_OK) {
    raise_error(operation, static_cast<int>(error));
  }
}

template <typename Function>
static value ffi_guard(const char *operation, Function function) {
  struct caml__roots_block *roots_before = CAML_LOCAL_ROOTS;
  int error_code = OWV_ERROR_CPP_EXCEPTION;
  char error_message[256] = {};
  try {
    return function();
  } catch (const std::bad_alloc &) {
    error_code = OWV_ERROR_OUT_OF_MEMORY;
    std::snprintf(error_message, sizeof(error_message), "%s", "C++ allocation failed");
  } catch (const std::exception &exception) {
    std::snprintf(error_message, sizeof(error_message), "%s", exception.what());
  } catch (...) {
    std::snprintf(error_message, sizeof(error_message), "%s",
                  "unknown C++ exception");
  }
  /* A C++ exception can bypass CAMLreturn in the implementation. Restore the
   * caller's root chain before allocating and raising the typed OCaml error. */
  CAML_LOCAL_ROOTS = roots_before;
  raise_error(operation, error_code, error_message);
}

template <typename Function>
static auto call_without_runtime(Function function) -> decltype(function()) {
  caml_release_runtime_system();
  try {
    if constexpr (std::is_void_v<decltype(function())>) {
      function();
      caml_acquire_runtime_system();
    } else {
      auto result = function();
      caml_acquire_runtime_system();
      return result;
    }
  } catch (...) {
    caml_acquire_runtime_system();
    throw;
  }
}

#if defined(__APPLE__)
using cocoa_completion_handler = void (^)(long);

static id cocoa_window_for_dialog(webview_t native) {
  id window = static_cast<id>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW));
  if (window != nullptr) return window;
  id application = ((id (*)(Class, SEL))objc_msgSend)(
      objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
  window = ((id (*)(id, SEL))objc_msgSend)(application,
                                            sel_registerName("keyWindow"));
  if (window == nullptr) {
    window = ((id (*)(id, SEL))objc_msgSend)(
        application, sel_registerName("mainWindow"));
  }
  return window;
}

struct cocoa_window_action {
  id window{};
  long button{};
};

static void perform_cocoa_window_action(void *context) {
  auto *action = static_cast<cocoa_window_action *>(context);
  switch (action->button) {
    case 0:
      ((void (*)(id, SEL, id))objc_msgSend)(
          action->window, sel_registerName("performClose:"), nullptr);
      break;
    case 1:
      ((void (*)(id, SEL, id))objc_msgSend)(
          action->window, sel_registerName("miniaturize:"), nullptr);
      break;
    case 2:
      ((void (*)(id, SEL, id))objc_msgSend)(
          action->window, sel_registerName("toggleFullScreen:"), nullptr);
      break;
    default: break;
  }
  ((void (*)(id, SEL))objc_msgSend)(action->window,
                                    sel_registerName("release"));
  delete action;
}

static void schedule_cocoa_window_action(id window, long button) {
  auto *action = new (std::nothrow) cocoa_window_action{window, button};
  if (action == nullptr) return;
  ((id (*)(id, SEL))objc_msgSend)(window, sel_registerName("retain"));
  dispatch_async_f(dispatch_get_main_queue(), action,
                   perform_cocoa_window_action);
}

#endif

static managed_webview *get_state(value handle, const char *operation,
                                  bool allow_closed = false) {
  managed_webview *state = State_val(handle);
  if (state == nullptr) {
    if (allow_closed) {
      return nullptr;
    }
    raise_error(operation, OWV_ERROR_CLOSED);
  }
  return state;
}

static bool is_owner_thread(managed_webview *state) {
  return state->owner_thread == std::this_thread::get_id();
}

static int begin_call(managed_webview *state, bool require_owner,
                      webview_t *native) {
  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->state == lifecycle::closed || state->native == nullptr ||
      state->native_window_closed) {
    return OWV_ERROR_CLOSED;
  }
  if (state->state == lifecycle::closing) {
    return OWV_ERROR_CLOSING;
  }
  if (require_owner && !is_owner_thread(state)) {
    return OWV_ERROR_WRONG_THREAD;
  }
  ++state->active_calls;
  *native = state->native;
  return WEBVIEW_ERROR_OK;
}

static void end_call(managed_webview *state) {
  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->active_calls > 0) {
    --state->active_calls;
  }
  if (state->active_calls == 0) {
    state->idle.notify_all();
  }
}

static void finalize_handle(value handle) {
  managed_webview *state = State_val(handle);
  if (state == nullptr) return;
  bool can_delete = false;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    can_delete = state->state == lifecycle::closed && state->native == nullptr;
  }
  if (can_delete) {
    delete state;
  } else {
    std::fprintf(stderr,
                 "owebview: a live Webview.t was collected without destroy; "
                 "native state was intentionally retained for safety\n");
  }
}

static struct custom_operations webview_custom_ops = {
    const_cast<char *>("owebview.managed_webview.v1"),
    finalize_handle,
    custom_compare_default,
    custom_hash_default,
    custom_serialize_default,
    custom_deserialize_default,
    custom_compare_ext_default,
    custom_fixed_length_default};

static void unregister_binding_root(binding_state *binding) {
  if (binding->root_registered) {
    caml_remove_generational_global_root(&binding->closure);
    binding->root_registered = false;
    binding->closure = Val_unit;
  }
}

static void unregister_dispatch_roots(dispatch_state *dispatch) {
  if (dispatch->closure_root_registered) {
    caml_remove_generational_global_root(&dispatch->closure);
    dispatch->closure_root_registered = false;
    dispatch->closure = Val_unit;
  }
  if (dispatch->handle_root_registered) {
    caml_remove_generational_global_root(&dispatch->handle);
    dispatch->handle_root_registered = false;
    dispatch->handle = Val_unit;
  }
}

static void unregister_dialog_roots(dialog_state *dialog) {
  if (dialog->completion_root_registered) {
    caml_remove_generational_global_root(&dialog->completion);
    dialog->completion_root_registered = false;
    dialog->completion = Val_unit;
  }
  if (dialog->handle_root_registered) {
    caml_remove_generational_global_root(&dialog->handle);
    dialog->handle_root_registered = false;
    dialog->handle = Val_unit;
  }
}

static void unregister_managed_callback_roots(managed_webview *state) {
  if (state->close_root_registered) {
    caml_remove_generational_global_root(&state->close_closure);
    state->close_root_registered = false;
    state->close_closure = Val_unit;
  }
  if (state->navigation_root_registered) {
    caml_remove_generational_global_root(&state->navigation_closure);
    state->navigation_root_registered = false;
    state->navigation_closure = Val_unit;
  }
  if (state->close_request_root_registered) {
    caml_remove_generational_global_root(&state->close_request_closure);
    state->close_request_root_registered = false;
    state->close_request_closure = Val_unit;
  }
  if (state->theme_root_registered) {
    caml_remove_generational_global_root(&state->theme_closure);
    state->theme_root_registered = false;
    state->theme_closure = Val_unit;
  }
}

static void retain_dialog_state(dialog_state *dialog) {
  dialog->references.fetch_add(1, std::memory_order_relaxed);
}

static void release_dialog_state(dialog_state *dialog) {
  if (dialog->references.fetch_sub(1, std::memory_order_acq_rel) != 1) return;
#if defined(__APPLE__)
  if (dialog->presenter != nullptr) {
    ((void (*)(id, SEL))objc_msgSend)(dialog->presenter,
                                      sel_registerName("release"));
    dialog->presenter = nullptr;
  }
  if (dialog->parent != nullptr) {
    ((void (*)(id, SEL))objc_msgSend)(dialog->parent,
                                      sel_registerName("release"));
    dialog->parent = nullptr;
  }
#endif
  delete dialog;
}

static void detach_pending_dialog(dialog_state *dialog) {
  managed_webview *owner = dialog->owner;
  if (owner == nullptr) return;
  {
    std::lock_guard<std::mutex> lock(owner->mutex);
#if defined(__APPLE__)
    if (owner->pending_dialog == dialog) {
      owner->pending_dialog = nullptr;
    }
#endif
  }
  dialog->owner = nullptr;
}

static void invoke_dialog_completion_with_runtime(
    dialog_state *dialog, int code, const char *message,
    const std::vector<std::string> &paths) {
  if (dialog->completed.exchange(true, std::memory_order_acq_rel)) return;
  detach_pending_dialog(dialog);
  CAMLparam0();
  CAMLlocal3(payload, results, item);
  CAMLlocalresult(callback_result);
  results = caml_alloc(static_cast<mlsize_t>(paths.size()), 0);
  for (mlsize_t index = 0; index < paths.size(); ++index) {
    item = caml_copy_string(paths[index].c_str());
    Store_field(results, index, item);
  }
  payload = caml_alloc_tuple(3);
  Store_field(payload, 0, Val_int(code));
  Store_field(payload, 1, caml_copy_string(message == nullptr ? "" : message));
  Store_field(payload, 2, results);
  callback_result = caml_callback_res(dialog->completion, payload);
  if (caml_result_is_exception(callback_result)) {
    std::fprintf(stderr, "owebview: native dialog completion callback raised\n");
  }
  unregister_dialog_roots(dialog);
  CAMLdrop;
}

#if defined(__APPLE__)
static dialog_state *retain_pending_dialog(managed_webview *state) {
  std::lock_guard<std::mutex> lock(state->mutex);
  dialog_state *dialog = state->pending_dialog;
  if (dialog != nullptr) retain_dialog_state(dialog);
  return dialog;
}

static std::vector<std::string> cocoa_dialog_paths(dialog_state *dialog,
                                                    long response) {
  std::vector<std::string> paths;
  if (response != 1 || dialog->kind == 0 || dialog->presenter == nullptr) {
    return paths;
  }
  if (dialog->kind == 4) {
    id url = ((id (*)(id, SEL))objc_msgSend)(dialog->presenter,
                                             sel_registerName("URL"));
    if (url != nullptr) {
      id path = ((id (*)(id, SEL))objc_msgSend)(url,
                                                 sel_registerName("path"));
      const char *text = path == nullptr
                             ? nullptr
                             : ((const char *(*)(id, SEL))objc_msgSend)(
                                   path, sel_registerName("UTF8String"));
      if (text != nullptr) paths.emplace_back(text);
    }
    return paths;
  }
  id urls = ((id (*)(id, SEL))objc_msgSend)(dialog->presenter,
                                             sel_registerName("URLs"));
  if (urls == nullptr) return paths;
  unsigned long count = ((unsigned long (*)(id, SEL))objc_msgSend)(
      urls, sel_registerName("count"));
  for (unsigned long index = 0; index < count; ++index) {
    id url = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
        urls, sel_registerName("objectAtIndex:"), index);
    id path = url == nullptr
                  ? nullptr
                  : ((id (*)(id, SEL))objc_msgSend)(url,
                                                     sel_registerName("path"));
    const char *text = path == nullptr
                           ? nullptr
                           : ((const char *(*)(id, SEL))objc_msgSend)(
                                 path, sel_registerName("UTF8String"));
    if (text != nullptr) paths.emplace_back(text);
  }
  return paths;
}

static void release_cocoa_dialog_chain(dialog_state *dialog) {
  if (dialog->close_after_completion.load(std::memory_order_acquire) &&
      !dialog->close_scheduled.exchange(true, std::memory_order_acq_rel) &&
      dialog->parent != nullptr) {
    schedule_cocoa_window_action(dialog->parent, 0);
  }
  release_dialog_state(dialog);
}

static void finish_cocoa_dialog(dialog_state *dialog, long response) noexcept {
  try {
    std::vector<std::string> paths = cocoa_dialog_paths(dialog, response);
    dialog->native_finished.store(true, std::memory_order_release);
    caml_acquire_runtime_system();
    invoke_dialog_completion_with_runtime(dialog, WEBVIEW_ERROR_OK, "", paths);
    caml_release_runtime_system();
  } catch (const std::exception &exception) {
    dialog->native_finished.store(true, std::memory_order_release);
    caml_acquire_runtime_system();
    invoke_dialog_completion_with_runtime(
        dialog, OWV_ERROR_CPP_EXCEPTION, exception.what(), {});
    caml_release_runtime_system();
  } catch (...) {
    dialog->native_finished.store(true, std::memory_order_release);
    caml_acquire_runtime_system();
    invoke_dialog_completion_with_runtime(
        dialog, OWV_ERROR_CPP_EXCEPTION,
        "unknown native dialog completion failure", {});
    caml_release_runtime_system();
  }
  release_cocoa_dialog_chain(dialog);
}

static id cocoa_string(const std::string &text) {
  return ((id (*)(Class, SEL, const char *))objc_msgSend)(
      objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"),
      text.c_str());
}

static void present_cocoa_dialog(void *context) noexcept {
  auto *dialog = static_cast<dialog_state *>(context);
  try {
    if (dialog->cancel_requested.load(std::memory_order_acquire)) {
      dialog->native_finished.store(true, std::memory_order_release);
      caml_acquire_runtime_system();
      invoke_dialog_completion_with_runtime(dialog, WEBVIEW_ERROR_OK, "", {});
      caml_release_runtime_system();
      release_cocoa_dialog_chain(dialog);
      return;
    }

    if (dialog->kind == 0) {
      dialog->presenter = ((id (*)(Class, SEL))objc_msgSend)(
          objc_getClass("NSAlert"), sel_registerName("new"));
      if (dialog->presenter != nullptr) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            dialog->presenter, sel_registerName("setMessageText:"),
            cocoa_string(dialog->title));
        ((void (*)(id, SEL, id))objc_msgSend)(
            dialog->presenter, sel_registerName("setInformativeText:"),
            cocoa_string(dialog->detail));
        ((void (*)(id, SEL, id))objc_msgSend)(
            dialog->presenter, sel_registerName("addButtonWithTitle:"),
            cocoa_string("OK"));
      }
    } else {
      dialog->presenter = dialog->kind == 4
                              ? ((id (*)(Class, SEL))objc_msgSend)(
                                    objc_getClass("NSSavePanel"),
                                    sel_registerName("savePanel"))
                              : ((id (*)(Class, SEL))objc_msgSend)(
                                    objc_getClass("NSOpenPanel"),
                                    sel_registerName("openPanel"));
      if (dialog->presenter != nullptr) {
        ((id (*)(id, SEL))objc_msgSend)(dialog->presenter,
                                        sel_registerName("retain"));
        ((void (*)(id, SEL, id))objc_msgSend)(
            dialog->presenter, sel_registerName("setTitle:"),
            cocoa_string(dialog->title));
        if (dialog->kind == 4 && !dialog->detail.empty()) {
          ((void (*)(id, SEL, id))objc_msgSend)(
              dialog->presenter, sel_registerName("setNameFieldStringValue:"),
              cocoa_string(dialog->detail));
        }
        if (dialog->kind != 4) {
          ((void (*)(id, SEL, bool))objc_msgSend)(
              dialog->presenter, sel_registerName("setCanChooseFiles:"),
              dialog->kind != 3);
          ((void (*)(id, SEL, bool))objc_msgSend)(
              dialog->presenter, sel_registerName("setCanChooseDirectories:"),
              dialog->kind == 3);
          ((void (*)(id, SEL, bool))objc_msgSend)(
              dialog->presenter,
              sel_registerName("setAllowsMultipleSelection:"),
              dialog->kind == 2);
        }
      }
    }

    if (dialog->presenter == nullptr || dialog->parent == nullptr) {
      dialog->native_finished.store(true, std::memory_order_release);
      caml_acquire_runtime_system();
      invoke_dialog_completion_with_runtime(
          dialog, WEBVIEW_ERROR_INVALID_STATE,
          "native dialog presenter is unavailable", {});
      caml_release_runtime_system();
      release_cocoa_dialog_chain(dialog);
      return;
    }

    dialog->presented.store(true, std::memory_order_release);
    cocoa_completion_handler completion = ^(long response) {
      finish_cocoa_dialog(dialog, response);
    };
    ((void (*)(id, SEL, id, cocoa_completion_handler))objc_msgSend)(
        dialog->presenter,
        sel_registerName("beginSheetModalForWindow:completionHandler:"),
        dialog->parent, completion);
  } catch (const std::exception &exception) {
    dialog->native_finished.store(true, std::memory_order_release);
    caml_acquire_runtime_system();
    invoke_dialog_completion_with_runtime(
        dialog, OWV_ERROR_CPP_EXCEPTION, exception.what(), {});
    caml_release_runtime_system();
    release_cocoa_dialog_chain(dialog);
  } catch (...) {
    dialog->native_finished.store(true, std::memory_order_release);
    caml_acquire_runtime_system();
    invoke_dialog_completion_with_runtime(
        dialog, OWV_ERROR_CPP_EXCEPTION,
        "unknown native dialog presentation failure", {});
    caml_release_runtime_system();
    release_cocoa_dialog_chain(dialog);
  }
}

static void cancel_cocoa_dialog(void *context) noexcept {
  auto *dialog = static_cast<dialog_state *>(context);
  if (dialog->presented.load(std::memory_order_acquire) &&
      !dialog->native_finished.load(std::memory_order_acquire) &&
      dialog->parent != nullptr) {
    id sheet = ((id (*)(id, SEL))objc_msgSend)(
        dialog->parent, sel_registerName("attachedSheet"));
    if (sheet == nullptr && dialog->presenter != nullptr) {
      id candidate = dialog->presenter;
      if (dialog->kind == 0) {
        candidate = ((id (*)(id, SEL))objc_msgSend)(
            dialog->presenter, sel_registerName("window"));
      }
      if (candidate != nullptr) {
        id sheet_parent = ((id (*)(id, SEL))objc_msgSend)(
            candidate, sel_registerName("sheetParent"));
        if (sheet_parent == dialog->parent) sheet = candidate;
      }
    }
    if (sheet != nullptr) {
      ((void (*)(id, SEL, id, long))objc_msgSend)(
          dialog->parent, sel_registerName("endSheet:returnCode:"), sheet, 0L);
    }
  }
  release_dialog_state(dialog);
}

static void request_cocoa_dialog_cancel(dialog_state *dialog) {
  dialog->cancel_requested.store(true, std::memory_order_release);
  retain_dialog_state(dialog);
  dispatch_async_f(dispatch_get_main_queue(), dialog, cancel_cocoa_dialog);
}

static void close_pending_dialog_with_runtime(managed_webview *state) {
  dialog_state *dialog = retain_pending_dialog(state);
  if (dialog == nullptr) return;
  request_cocoa_dialog_cancel(dialog);
  invoke_dialog_completion_with_runtime(
      dialog, OWV_ERROR_CLOSED, "window closed while native dialog was active",
      {});
  release_dialog_state(dialog);
}
#else
static void close_pending_dialog_with_runtime(managed_webview *) {}
#endif

static void cleanup_managed_state(managed_webview *state) {
  close_pending_dialog_with_runtime(state);
  unregister_managed_callback_roots(state);
  for (binding_state *binding : state->all_bindings) {
    unregister_binding_root(binding);
    delete binding;
  }
  state->all_bindings.clear();
  state->active_bindings.clear();
  std::vector<dispatch_state *> executing_dispatches;
  for (dispatch_state *dispatch : state->all_dispatches) {
    if (dispatch->executing.load(std::memory_order_acquire)) {
      executing_dispatches.push_back(dispatch);
    } else {
      unregister_dispatch_roots(dispatch);
      delete dispatch;
    }
  }
  state->all_dispatches.swap(executing_dispatches);
}

static std::string current_url(webview_t native) {
#if defined(__APPLE__)
  id browser = static_cast<id>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER));
  if (browser == nullptr) return "";
  id url = ((id (*)(id, SEL))objc_msgSend)(browser, sel_registerName("URL"));
  if (url == nullptr) return "";
  id absolute = ((id (*)(id, SEL))objc_msgSend)(
      url, sel_registerName("absoluteString"));
  if (absolute == nullptr) return "";
  const char *text = ((const char *(*)(id, SEL))objc_msgSend)(
      absolute, sel_registerName("UTF8String"));
  return text == nullptr ? "" : text;
#elif defined(__linux__)
  auto *browser = static_cast<WebKitWebView *>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER));
  if (browser == nullptr) return "";
  const char *uri = webkit_web_view_get_uri(browser);
  return uri == nullptr ? "" : uri;
#else
  (void)native;
  return "";
#endif
}

static bool open_external_url(const char *url) {
#if defined(__APPLE__)
  id ns_url = ((id (*)(Class, SEL, id))objc_msgSend)(
      objc_getClass("NSURL"), sel_registerName("URLWithString:"),
      ((id (*)(Class, SEL, const char *))objc_msgSend)(
          objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"),
          url));
  id workspace = ((id (*)(Class, SEL))objc_msgSend)(
      objc_getClass("NSWorkspace"), sel_registerName("sharedWorkspace"));
  return ns_url != nullptr && workspace != nullptr &&
         ((bool (*)(id, SEL, id))objc_msgSend)(
             workspace, sel_registerName("openURL:"), ns_url);
#elif defined(__linux__)
  return g_app_info_launch_default_for_uri(url, nullptr, nullptr) != FALSE;
#elif defined(_WIN32)
  int size = MultiByteToWideChar(CP_UTF8, 0, url, -1, nullptr, 0);
  if (size <= 0) return false;
  std::vector<wchar_t> wide(static_cast<std::size_t>(size));
  if (MultiByteToWideChar(CP_UTF8, 0, url, -1, wide.data(), size) <= 0)
    return false;
  return reinterpret_cast<INT_PTR>(
             ShellExecuteW(nullptr, L"open", wide.data(), nullptr, nullptr,
                           SW_SHOWNORMAL)) > 32;
#else
  (void)url;
  return false;
#endif
}

static void notify_window_closed_with_runtime(managed_webview *state) {
  bool invoke = false;
  bool already_closed = false;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    already_closed = state->native_window_closed;
    if (!already_closed) {
      state->native_window_closed = true;
      if (state->state == lifecycle::running) state->state = lifecycle::stopped;
      invoke = state->close_root_registered;
    }
  }
  close_pending_dialog_with_runtime(state);
  if (already_closed) return;
  if (!invoke) return;
  CAMLparam0();
  CAMLlocalresult(result);
  result = caml_callback_res(state->close_closure, Val_unit);
  if (caml_result_is_exception(result)) {
    std::fprintf(stderr, "owebview: close callback raised an OCaml exception\n");
  }
  CAMLdrop;
}

static void notify_window_closed(managed_webview *state) {
  caml_acquire_runtime_system();
  notify_window_closed_with_runtime(state);
  caml_release_runtime_system();
}

static int navigation_decision(managed_webview *state, const char *url) {
  if (!state->navigation_root_registered) return 0;
  caml_acquire_runtime_system();
  CAMLparam0();
  CAMLlocal1(v_url);
  CAMLlocalresult(result);
  v_url = caml_copy_string(url == nullptr ? "" : url);
  result = caml_callback_res(state->navigation_closure, v_url);
  int decision = 1;
  if (caml_result_is_exception(result)) {
    std::fprintf(stderr,
                 "owebview: navigation policy raised; rejecting navigation\n");
  } else {
    decision = Int_val(result.data);
  }
  CAMLdrop;
  caml_release_runtime_system();
  return decision;
}

static bool should_close_window(managed_webview *state) {
  if (!state->close_request_root_registered) return true;
  caml_acquire_runtime_system();
  CAMLparam0();
  CAMLlocalresult(result);
  result = caml_callback_res(state->close_request_closure, Val_unit);
  bool allow = false;
  if (caml_result_is_exception(result)) {
    std::fprintf(stderr,
                 "owebview: close-interception callback raised; keeping window open\n");
  } else {
    allow = Bool_val(result.data);
  }
  CAMLdrop;
  caml_release_runtime_system();
  return allow;
}

static int system_theme_value() {
#if defined(__APPLE__)
  id app = ((id (*)(Class, SEL))objc_msgSend)(
      objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
  id appearance = ((id (*)(id, SEL))objc_msgSend)(
      app, sel_registerName("effectiveAppearance"));
  id name = appearance == nullptr
                ? nullptr
                : ((id (*)(id, SEL))objc_msgSend)(appearance,
                                                  sel_registerName("name"));
  const char *text = name == nullptr
                         ? nullptr
                         : ((const char *(*)(id, SEL))objc_msgSend)(
                               name, sel_registerName("UTF8String"));
  if (text == nullptr) return 2;
  return std::string(text).find("Dark") != std::string::npos ? 1 : 0;
#elif defined(__linux__)
  GtkSettings *settings = gtk_settings_get_default();
  gchar *theme_name = nullptr;
  if (settings != nullptr)
    g_object_get(settings, "gtk-theme-name", &theme_name, nullptr);
  if (theme_name == nullptr) return 2;
  std::string name(theme_name);
  for (char &ch : name) ch = static_cast<char>(std::tolower(ch));
  g_free(theme_name);
  return name.find("dark") != std::string::npos ? 1 : 0;
#elif defined(_WIN32)
  HKEY key = nullptr;
  DWORD value = 1;
  DWORD size = sizeof(value);
  if (RegOpenKeyExW(
          HKEY_CURRENT_USER,
          L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
          0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS)
    return 2;
  LONG status = RegQueryValueExW(key, L"AppsUseLightTheme", nullptr, nullptr,
                                 reinterpret_cast<BYTE *>(&value), &size);
  RegCloseKey(key);
  return status == ERROR_SUCCESS ? (value == 0 ? 1 : 0) : 2;
#else
  return 2;
#endif
}

static void notify_theme_changed(managed_webview *state) {
  if (!state->theme_root_registered) return;
  caml_acquire_runtime_system();
  CAMLparam0();
  CAMLlocalresult(result);
  result = caml_callback_res(state->theme_closure,
                             Val_int(system_theme_value()));
  if (caml_result_is_exception(result)) {
    std::fprintf(stderr, "owebview: theme callback raised an OCaml exception\n");
  }
  CAMLdrop;
  caml_release_runtime_system();
}

#if defined(__APPLE__)
static char close_state_key;
static char navigation_state_key;
static char close_request_state_key;
static char theme_state_key;
static char titlebar_action_key;

struct cocoa_titlebar_action {
  id window{};
  long button{};
  Class original_class{};
};

static managed_webview *associated_state(id object, const void *key) {
  id boxed = objc_getAssociatedObject(object, key);
  if (boxed == nullptr) return nullptr;
  return static_cast<managed_webview *>(
      ((void *(*)(id, SEL))objc_msgSend)(boxed,
                                         sel_registerName("pointerValue")));
}

static void associate_state(id object, const void *key,
                            managed_webview *state) {
  id boxed = ((id (*)(Class, SEL, const void *))objc_msgSend)(
      objc_getClass("NSValue"), sel_registerName("valueWithPointer:"), state);
  objc_setAssociatedObject(object, key, boxed, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static cocoa_titlebar_action *associated_titlebar_action(id object) {
  id boxed = objc_getAssociatedObject(object, &titlebar_action_key);
  if (boxed == nullptr) return nullptr;
  return static_cast<cocoa_titlebar_action *>(
      ((void *(*)(id, SEL))objc_msgSend)(boxed,
                                         sel_registerName("pointerValue")));
}

static Class fullscreen_button_class(Class superclass) {
  const char *name = "OwebviewFullscreenButton";
  Class cls = objc_lookUpClass(name);
  if (cls != nullptr) {
    return class_getSuperclass(cls) == superclass ? cls : nullptr;
  }
  cls = objc_allocateClassPair(superclass, name, 0);
  if (cls == nullptr) return nullptr;
  class_addMethod(
      cls, sel_registerName("mouseDown:"),
      reinterpret_cast<IMP>(+[](id self, SEL, id) {
        if (auto *action = associated_titlebar_action(self)) {
          schedule_cocoa_window_action(action->window, action->button);
        }
      }),
      "v@:@");
  objc_registerClassPair(cls);
  return cls;
}

static id install_cocoa_titlebar_button(id window, long button_kind) {
  id button = ((id (*)(id, SEL, long))objc_msgSend)(
      window, sel_registerName("standardWindowButton:"), button_kind);
  if (button == nullptr) return nullptr;
  Class original_class = object_getClass(button);
  Class replacement_class = fullscreen_button_class(original_class);
  if (replacement_class == nullptr) return nullptr;
  auto *action =
      new (std::nothrow) cocoa_titlebar_action{window, button_kind,
                                               original_class};
  if (action == nullptr) return nullptr;
  id boxed = ((id (*)(Class, SEL, const void *))objc_msgSend)(
      objc_getClass("NSValue"), sel_registerName("valueWithPointer:"), action);
  objc_setAssociatedObject(button, &titlebar_action_key, boxed,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  object_setClass(button, replacement_class);
  ((id (*)(id, SEL))objc_msgSend)(button, sel_registerName("retain"));
  return button;
}

static void remove_cocoa_titlebar_button(id button) {
  if (button == nullptr) return;
  auto *action = associated_titlebar_action(button);
  if (action != nullptr && action->original_class != nullptr) {
    object_setClass(button, action->original_class);
  }
  objc_setAssociatedObject(button, &titlebar_action_key, nullptr,
                           OBJC_ASSOCIATION_ASSIGN);
  ((void (*)(id, SEL))objc_msgSend)(button, sel_registerName("release"));
  delete action;
}

static void refresh_cocoa_fullscreen_button(managed_webview *state,
                                            id window) {
  remove_cocoa_titlebar_button(state->fullscreen_button);
  state->fullscreen_button = install_cocoa_titlebar_button(window, 2);
}

static Class close_observer_class() {
  const char *name = "OwebviewCloseObserver";
  Class cls = objc_lookUpClass(name);
  if (cls != nullptr) return cls;
  cls = objc_allocateClassPair(objc_getClass("NSObject"), name, 0);
  class_addMethod(
      cls, sel_registerName("windowWillClose:"),
      reinterpret_cast<IMP>(+[](id self, SEL, id) {
        if (auto *state = associated_state(self, &close_state_key)) {
          notify_window_closed(state);
        }
      }),
      "v@:@");
  objc_registerClassPair(cls);
  return cls;
}

static Class theme_observer_class() {
  const char *name = "OwebviewThemeObserver";
  Class cls = objc_lookUpClass(name);
  if (cls != nullptr) return cls;
  cls = objc_allocateClassPair(objc_getClass("NSObject"), name, 0);
  class_addMethod(
      cls, sel_registerName("themeChanged:"),
      reinterpret_cast<IMP>(+[](id self, SEL, id) {
        if (auto *state = associated_state(self, &theme_state_key)) {
          notify_theme_changed(state);
        }
      }),
      "v@:@");
  objc_registerClassPair(cls);
  return cls;
}

static void invoke_navigation_decision_handler(id handler, long policy) {
  id signature = ((id (*)(Class, SEL, const char *))objc_msgSend)(
      objc_getClass("NSMethodSignature"),
      sel_registerName("signatureWithObjCTypes:"), "v@?q");
  id invocation = ((id (*)(Class, SEL, id))objc_msgSend)(
      objc_getClass("NSInvocation"),
      sel_registerName("invocationWithMethodSignature:"), signature);
  ((void (*)(id, SEL, id))objc_msgSend)(invocation,
                                        sel_registerName("setTarget:"), handler);
  ((void (*)(id, SEL, void *, long))objc_msgSend)(
      invocation, sel_registerName("setArgument:atIndex:"), &policy, 1L);
  ((void (*)(id, SEL))objc_msgSend)(invocation, sel_registerName("invoke"));
}

static Class navigation_delegate_class() {
  const char *name = "OwebviewNavigationDelegate";
  Class cls = objc_lookUpClass(name);
  if (cls != nullptr) return cls;
  cls = objc_allocateClassPair(objc_getClass("NSObject"), name, 0);
  Protocol *protocol = objc_getProtocol("WKNavigationDelegate");
  if (protocol != nullptr) class_addProtocol(cls, protocol);
  class_addMethod(
      cls,
      sel_registerName(
          "webView:decidePolicyForNavigationAction:decisionHandler:"),
      reinterpret_cast<IMP>(+[](id self, SEL, id, id action, id handler) {
        auto *state = associated_state(self, &navigation_state_key);
        id request = ((id (*)(id, SEL))objc_msgSend)(
            action, sel_registerName("request"));
        id url = request == nullptr
                     ? nullptr
                     : ((id (*)(id, SEL))objc_msgSend)(
                           request, sel_registerName("URL"));
        id absolute = url == nullptr
                          ? nullptr
                          : ((id (*)(id, SEL))objc_msgSend)(
                                url, sel_registerName("absoluteString"));
        const char *text =
            absolute == nullptr
                ? ""
                : ((const char *(*)(id, SEL))objc_msgSend)(
                      absolute, sel_registerName("UTF8String"));
        int decision = state == nullptr ? 1 : navigation_decision(state, text);
        if (decision == 2 && text != nullptr) open_external_url(text);
        invoke_navigation_decision_handler(handler, decision == 0 ? 1L : 0L);
      }),
      "v@:@@@");
  objc_registerClassPair(cls);
  return cls;
}
#endif

static void remove_platform_hooks(managed_webview *state, webview_t native) {
#if defined(__APPLE__)
  remove_cocoa_titlebar_button(state->fullscreen_button);
  state->fullscreen_button = nullptr;
  id center = ((id (*)(Class, SEL))objc_msgSend)(
      objc_getClass("NSNotificationCenter"),
      sel_registerName("defaultCenter"));
  if (state->close_observer != nullptr) {
    ((void (*)(id, SEL, id))objc_msgSend)(center,
                                          sel_registerName("removeObserver:"),
                                          state->close_observer);
    ((void (*)(id, SEL))objc_msgSend)(state->close_observer,
                                      sel_registerName("release"));
    state->close_observer = nullptr;
  }
  if (state->navigation_delegate != nullptr) {
    id browser = static_cast<id>(webview_get_native_handle(
        native, WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER));
    if (browser != nullptr) {
      ((void (*)(id, SEL, id))objc_msgSend)(
          browser, sel_registerName("setNavigationDelegate:"), nullptr);
    }
    ((void (*)(id, SEL))objc_msgSend)(state->navigation_delegate,
                                      sel_registerName("release"));
    state->navigation_delegate = nullptr;
  }
  if (state->theme_observer != nullptr) {
    id distributed = ((id (*)(Class, SEL))objc_msgSend)(
        objc_getClass("NSDistributedNotificationCenter"),
        sel_registerName("defaultCenter"));
    ((void (*)(id, SEL, id))objc_msgSend)(
        distributed, sel_registerName("removeObserver:"),
        state->theme_observer);
    ((void (*)(id, SEL))objc_msgSend)(state->theme_observer,
                                      sel_registerName("release"));
    state->theme_observer = nullptr;
  }
#elif defined(__linux__)
  auto *window = static_cast<GtkWidget *>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW));
  auto *browser = static_cast<WebKitWebView *>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER));
  if (window != nullptr && state->close_signal != 0) {
    g_signal_handler_disconnect(window, state->close_signal);
    state->close_signal = 0;
  }
  if (window != nullptr && state->close_request_signal != 0) {
    g_signal_handler_disconnect(window, state->close_request_signal);
    state->close_request_signal = 0;
  }
  if (browser != nullptr && state->navigation_signal != 0) {
    g_signal_handler_disconnect(browser, state->navigation_signal);
    state->navigation_signal = 0;
  }
  if (state->theme_signal != 0) {
    GtkSettings *settings = gtk_settings_get_default();
    if (settings != nullptr)
      g_signal_handler_disconnect(settings, state->theme_signal);
    state->theme_signal = 0;
  }
#else
  (void)state;
  (void)native;
#endif
}

static void binding_trampoline_impl(const char *id, const char *request,
                                    void *arg) {
  auto *binding = static_cast<binding_state *>(arg);
  if (!binding->active.load(std::memory_order_acquire)) {
    webview_return(binding->owner->native, id, 1,
                   R"({"code":"binding_inactive","message":"binding is no longer active"})");
    return;
  }

  caml_acquire_runtime_system();
  CAMLparam0();
  CAMLlocal3(v_id, v_request, v_url);
  CAMLlocalresult(callback_result);
  v_id = caml_copy_string(id);
  v_request = caml_copy_string(request);
  if (binding->include_url) {
    const std::string url = current_url(binding->owner->native);
    v_url = caml_copy_string(url.c_str());
    callback_result =
        caml_callback3_res(binding->closure, v_id, v_request, v_url);
  } else {
    callback_result = caml_callback2_res(binding->closure, v_id, v_request);
  }
  const bool raised = caml_result_is_exception(callback_result);
  CAMLdrop;
  caml_release_runtime_system();

  if (raised) {
    std::fprintf(stderr, "owebview: binding '%s' raised an OCaml exception\n",
                 binding->name.c_str());
    webview_return(binding->owner->native, id, 1,
                   R"({"code":"ocaml_exception","message":"binding handler raised"})");
  }
}

static void binding_trampoline(const char *id, const char *request,
                               void *arg) noexcept {
  try {
    binding_trampoline_impl(id, request, arg);
  } catch (const std::exception &exception) {
    std::fprintf(stderr, "owebview: C++ exception in binding callback: %s\n",
                 exception.what());
    try {
      auto *binding = static_cast<binding_state *>(arg);
      webview_return(binding->owner->native, id, 1,
                     R"({"code":"native_exception","message":"native binding callback failed"})");
    } catch (...) {
      std::fprintf(stderr,
                   "owebview: failed to reject binding after C++ exception\n");
    }
  } catch (...) {
    std::fprintf(stderr, "owebview: unknown C++ exception in binding callback\n");
  }
}

static void dispatch_trampoline_impl(webview_t, void *arg) {
  auto *dispatch = static_cast<dispatch_state *>(arg);
  dispatch->executing.store(true, std::memory_order_release);
  caml_acquire_runtime_system();
  CAMLparam0();
  CAMLlocalresult(callback_result);

  bool invoke = false;
  {
    std::lock_guard<std::mutex> lock(dispatch->owner->mutex);
    invoke = dispatch->owner->state != lifecycle::closing &&
             dispatch->owner->state != lifecycle::closed;
  }
  if (invoke) {
    callback_result = caml_callback_res(dispatch->closure, dispatch->handle);
    if (caml_result_is_exception(callback_result)) {
      std::fprintf(stderr, "owebview: dispatched OCaml callback raised\n");
    }
  }
  dispatch->completed.store(true, std::memory_order_release);
  {
    std::lock_guard<std::mutex> lock(dispatch->owner->mutex);
    auto &dispatches = dispatch->owner->all_dispatches;
    for (auto current = dispatches.begin(); current != dispatches.end();
         ++current) {
      if (*current == dispatch) {
        dispatches.erase(current);
        break;
      }
    }
  }
  unregister_dispatch_roots(dispatch);
  CAMLdrop;
  caml_release_runtime_system();
  delete dispatch;
}

static void dispatch_trampoline(webview_t webview, void *arg) noexcept {
  try {
    dispatch_trampoline_impl(webview, arg);
  } catch (const std::exception &exception) {
    std::fprintf(stderr, "owebview: C++ exception in dispatch callback: %s\n",
                 exception.what());
  } catch (...) {
    std::fprintf(stderr, "owebview: unknown C++ exception in dispatch callback\n");
  }
}

#if defined(__APPLE__)
static void deferred_dispatch_timer(CFRunLoopTimerRef timer, void *arg) {
  CFRunLoopTimerInvalidate(timer);
  dispatch_trampoline(nullptr, arg);
}
#elif defined(__linux__)
static gboolean deferred_dispatch_idle(gpointer arg) {
  dispatch_trampoline(nullptr, arg);
  return G_SOURCE_REMOVE;
}
#endif

static webview_native_handle_kind_t native_handle_kind(value kind) {
  switch (Int_val(kind)) {
    case 1:
      return WEBVIEW_NATIVE_HANDLE_KIND_UI_WIDGET;
    case 2:
      return WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER;
    default:
      return WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW;
  }
}

}  // namespace

extern "C" {

#define OWV_FFI1(name, operation, argument1)                                 \
  static value name##_impl(value argument1);                                 \
  CAMLprim value name(value argument1) {                                     \
    return ffi_guard(operation, [&] { return name##_impl(argument1); });      \
  }                                                                           \
  static value name##_impl(value argument1)

#define OWV_FFI2(name, operation, argument1, argument2)                       \
  static value name##_impl(value argument1, value argument2);                 \
  CAMLprim value name(value argument1, value argument2) {                     \
    return ffi_guard(operation,                                               \
                     [&] { return name##_impl(argument1, argument2); });       \
  }                                                                           \
  static value name##_impl(value argument1, value argument2)

#define OWV_FFI3(name, operation, argument1, argument2, argument3)            \
  static value name##_impl(value argument1, value argument2, value argument3);\
  CAMLprim value name(value argument1, value argument2, value argument3) {    \
    return ffi_guard(                                                         \
        operation, [&] { return name##_impl(argument1, argument2, argument3); });\
  }                                                                           \
  static value name##_impl(value argument1, value argument2, value argument3)

#define OWV_FFI4(name, operation, argument1, argument2, argument3, argument4) \
  static value name##_impl(value argument1, value argument2, value argument3, \
                           value argument4);                                  \
  CAMLprim value name(value argument1, value argument2, value argument3,      \
                      value argument4) {                                      \
    return ffi_guard(operation, [&] {                                         \
      return name##_impl(argument1, argument2, argument3, argument4);         \
    });                                                                       \
  }                                                                           \
  static value name##_impl(value argument1, value argument2, value argument3, \
                           value argument4)

OWV_FFI1(ocaml_webview_create, "webview_create", debug) {
  CAMLparam1(debug);
  CAMLlocal1(handle);
  handle = caml_alloc_custom(&webview_custom_ops, sizeof(managed_webview *), 0, 1);
  State_val(handle) = nullptr;

  auto *state = new (std::nothrow) managed_webview();
  if (state == nullptr) {
    raise_error("webview_create", OWV_ERROR_OUT_OF_MEMORY);
  }
  state->owner_thread = std::this_thread::get_id();
  state->native = webview_create(Bool_val(debug), nullptr);
  if (state->native == nullptr) {
    delete state;
    raise_error("webview_create", WEBVIEW_ERROR_UNSPECIFIED,
                "webview_create returned NULL");
  }
  State_val(handle) = state;
  CAMLreturn(handle);
}

OWV_FFI1(ocaml_webview_is_closed, "webview_is_closed", handle) {
  CAMLparam1(handle);
  managed_webview *state = State_val(handle);
  if (state == nullptr) {
    CAMLreturn(Val_true);
  }
  bool closed = false;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    closed = state->state == lifecycle::closing ||
             state->state == lifecycle::closed || state->native_window_closed;
  }
  CAMLreturn(Val_bool(closed));
}

OWV_FFI1(ocaml_webview_destroy, "webview_destroy", handle) {
  CAMLparam1(handle);
  managed_webview *state = get_state(handle, "webview_destroy", true);
  if (state == nullptr) {
    CAMLreturn(Val_unit);
  }
  if (!is_owner_thread(state)) {
    raise_error("webview_destroy", OWV_ERROR_WRONG_THREAD);
  }

  webview_t native = nullptr;
  bool already_closing = false;
  bool running = false;
  {
    std::unique_lock<std::mutex> lock(state->mutex);
    if (state->state == lifecycle::running) {
      running = true;
    } else if (state->state == lifecycle::closing ||
               state->state == lifecycle::closed) {
      already_closing = true;
    } else {
      state->state = lifecycle::closing;
      state->idle.wait(lock, [state] { return state->active_calls == 0; });
      native = state->native;
    }
  }
  if (running)
    raise_error("webview_destroy", OWV_ERROR_INVALID_LIFECYCLE,
                "terminate and wait for run to return before destroy");
  if (already_closing) CAMLreturn(Val_unit);

  remove_platform_hooks(state, native);

  webview_error_t error =
      call_without_runtime([&] { return webview_destroy(native); });
  if (error != WEBVIEW_ERROR_OK) {
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      state->state = lifecycle::stopped;
    }
    check_error("webview_destroy", error);
  }

  notify_window_closed_with_runtime(state);
  cleanup_managed_state(state);
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->native = nullptr;
    state->state = lifecycle::closed;
  }
  /* Keep the small closed state record until the OCaml custom block is
   * finalized. Other Domains may still hold the handle and must observe a
   * deterministic Closed error rather than a freed pointer. */
  CAMLreturn(Val_unit);
}

OWV_FFI1(ocaml_webview_run, "webview_run", handle) {
  CAMLparam1(handle);
  managed_webview *state = get_state(handle, "webview_run");
  if (!is_owner_thread(state)) {
    raise_error("webview_run", OWV_ERROR_WRONG_THREAD);
  }
  webview_t native = nullptr;
  bool invalid_lifecycle = false;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->state != lifecycle::created) {
      invalid_lifecycle = true;
    } else {
      state->state = lifecycle::running;
      native = state->native;
    }
  }
  if (invalid_lifecycle)
    raise_error("webview_run", OWV_ERROR_INVALID_LIFECYCLE,
                "webview_run may be called only once");
#if defined(__APPLE__)
  id window = static_cast<id>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW));
  refresh_cocoa_fullscreen_button(state, window);
#endif
  webview_error_t error =
      call_without_runtime([&] { return webview_run(native); });
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->state == lifecycle::running) {
      state->state = lifecycle::stopped;
    }
  }
  check_error("webview_run", error);
  CAMLreturn(Val_unit);
}

OWV_FFI1(ocaml_webview_terminate, "webview_terminate", handle) {
  CAMLparam1(handle);
  managed_webview *state = get_state(handle, "webview_terminate");
  webview_t native = nullptr;
  int status = begin_call(state, false, &native);
  if (status != WEBVIEW_ERROR_OK) {
    raise_error("webview_terminate", status);
  }
  webview_error_t error = webview_terminate(native);
  end_call(state);
  check_error("webview_terminate", error);
  CAMLreturn(Val_unit);
}

#define OWV_UI_STRING_PRIMITIVE(caml_name, c_name)                            \
  OWV_FFI2(caml_name, #c_name, handle, argument) {                            \
    CAMLparam2(handle, argument);                                              \
    managed_webview *state = get_state(handle, #c_name);                       \
    webview_t native = nullptr;                                                \
    int status = begin_call(state, true, &native);                             \
    if (status != WEBVIEW_ERROR_OK) raise_error(#c_name, status);              \
    webview_error_t error = c_name(native, String_val(argument));              \
    end_call(state);                                                           \
    check_error(#c_name, error);                                               \
    CAMLreturn(Val_unit);                                                      \
  }

OWV_UI_STRING_PRIMITIVE(ocaml_webview_set_title, webview_set_title)
OWV_UI_STRING_PRIMITIVE(ocaml_webview_navigate, webview_navigate)
OWV_UI_STRING_PRIMITIVE(ocaml_webview_set_html, webview_set_html)
OWV_UI_STRING_PRIMITIVE(ocaml_webview_init, webview_init)
OWV_UI_STRING_PRIMITIVE(ocaml_webview_eval, webview_eval)

OWV_FFI4(ocaml_webview_set_size, "webview_set_size", handle, width, height,
         hint) {
  CAMLparam4(handle, width, height, hint);
  managed_webview *state = get_state(handle, "webview_set_size");
  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) raise_error("webview_set_size", status);
  webview_hint_t native_hint = WEBVIEW_HINT_NONE;
  switch (Int_val(hint)) {
    case 1: native_hint = WEBVIEW_HINT_MIN; break;
    case 2: native_hint = WEBVIEW_HINT_MAX; break;
    case 3: native_hint = WEBVIEW_HINT_FIXED; break;
    default: break;
  }
  webview_error_t error =
      webview_set_size(native, Int_val(width), Int_val(height), native_hint);
  end_call(state);
  check_error("webview_set_size", error);
  CAMLreturn(Val_unit);
}

OWV_FFI4(ocaml_webview_return, "webview_return", handle, id, status_value,
         result) {
  CAMLparam4(handle, id, status_value, result);
  managed_webview *state = get_state(handle, "webview_return");
  webview_t native = nullptr;
  int status = begin_call(state, false, &native);
  if (status != WEBVIEW_ERROR_OK) raise_error("webview_return", status);
  webview_error_t error =
      webview_return(native, String_val(id), Int_val(status_value),
                     String_val(result));
  end_call(state);
  check_error("webview_return", error);
  CAMLreturn(Val_unit);
}

OWV_FFI3(ocaml_webview_bind, "webview_bind", handle, name, closure) {
  CAMLparam3(handle, name, closure);
  managed_webview *state = get_state(handle, "webview_bind");
  if (!is_owner_thread(state)) raise_error("webview_bind", OWV_ERROR_WRONG_THREAD);

  auto *binding = new (std::nothrow) binding_state();
  if (binding == nullptr) raise_error("webview_bind", OWV_ERROR_OUT_OF_MEMORY);
  binding->owner = state;
  binding->closure = closure;
  binding->include_url = false;
  bool name_ok = true;
  char exception_message[256] = {};
  try {
    binding->name = String_val(name);
  } catch (const std::exception &exception) {
    std::snprintf(exception_message, sizeof(exception_message), "%s",
                  exception.what());
    name_ok = false;
  }
  if (!name_ok) {
    delete binding;
    raise_error("webview_bind", OWV_ERROR_CPP_EXCEPTION, exception_message);
  }
  caml_register_generational_global_root(&binding->closure);
  binding->root_registered = true;

  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) {
    unregister_binding_root(binding);
    delete binding;
    raise_error("webview_bind", status);
  }
  webview_error_t error =
      webview_bind(native, binding->name.c_str(), binding_trampoline, binding);
  end_call(state);
  if (error != WEBVIEW_ERROR_OK) {
    unregister_binding_root(binding);
    delete binding;
    check_error("webview_bind", error);
  }

  bool bookkeeping_ok = true;
  exception_message[0] = '\0';
  try {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->all_bindings.push_back(binding);
    state->active_bindings.emplace(binding->name, binding);
  } catch (const std::exception &exception) {
    std::snprintf(exception_message, sizeof(exception_message), "%s",
                  exception.what());
    bookkeeping_ok = false;
  }
  if (!bookkeeping_ok) {
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      state->active_bindings.erase(binding->name);
      if (!state->all_bindings.empty() &&
          state->all_bindings.back() == binding) {
        state->all_bindings.pop_back();
      }
    }
    webview_unbind(native, binding->name.c_str());
    unregister_binding_root(binding);
    delete binding;
    raise_error("webview_bind", OWV_ERROR_CPP_EXCEPTION, exception_message);
  }
  CAMLreturn(Val_unit);
}

OWV_FFI3(ocaml_webview_bind_with_url, "webview_bind_with_url", handle, name,
         closure) {
  CAMLparam3(handle, name, closure);
  managed_webview *state = get_state(handle, "webview_bind_with_url");
  if (!is_owner_thread(state))
    raise_error("webview_bind_with_url", OWV_ERROR_WRONG_THREAD);

  auto *binding = new (std::nothrow) binding_state();
  if (binding == nullptr)
    raise_error("webview_bind_with_url", OWV_ERROR_OUT_OF_MEMORY);
  binding->owner = state;
  binding->closure = closure;
  binding->include_url = true;
  binding->name = String_val(name);
  caml_register_generational_global_root(&binding->closure);
  binding->root_registered = true;

  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) {
    unregister_binding_root(binding);
    delete binding;
    raise_error("webview_bind_with_url", status);
  }
  webview_error_t error =
      webview_bind(native, binding->name.c_str(), binding_trampoline, binding);
  end_call(state);
  if (error != WEBVIEW_ERROR_OK) {
    unregister_binding_root(binding);
    delete binding;
    check_error("webview_bind_with_url", error);
  }
  try {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->all_bindings.push_back(binding);
    state->active_bindings.emplace(binding->name, binding);
  } catch (...) {
    webview_unbind(native, binding->name.c_str());
    unregister_binding_root(binding);
    delete binding;
    throw;
  }
  CAMLreturn(Val_unit);
}

OWV_FFI2(ocaml_webview_unbind, "webview_unbind", handle, name) {
  CAMLparam2(handle, name);
  managed_webview *state = get_state(handle, "webview_unbind");
  if (!is_owner_thread(state)) raise_error("webview_unbind", OWV_ERROR_WRONG_THREAD);

  binding_state *binding = nullptr;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    auto found = state->active_bindings.find(String_val(name));
    if (found != state->active_bindings.end()) binding = found->second;
  }
  if (binding == nullptr) raise_error("webview_unbind", WEBVIEW_ERROR_NOT_FOUND);

  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) raise_error("webview_unbind", status);
  webview_error_t error = webview_unbind(native, String_val(name));
  end_call(state);
  check_error("webview_unbind", error);

  binding->active.store(false, std::memory_order_release);
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->active_bindings.erase(binding->name);
  }
  /* Keep the rooted record until destroy: upstream may already have queued a
   * callback containing its raw user-data pointer. */
  CAMLreturn(Val_unit);
}

OWV_FFI1(ocaml_webview_current_url, "webview_current_url", handle) {
  CAMLparam1(handle);
  CAMLlocal1(result);
  managed_webview *state = get_state(handle, "webview_current_url");
  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) raise_error("webview_current_url", status);
  const std::string url = current_url(native);
  end_call(state);
  result = caml_copy_string(url.c_str());
  CAMLreturn(result);
}

OWV_FFI1(ocaml_webview_reload, "webview_reload", handle) {
  CAMLparam1(handle);
  managed_webview *state = get_state(handle, "webview_reload");
  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) raise_error("webview_reload", status);
#if defined(__APPLE__)
  id browser = static_cast<id>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER));
  if (browser != nullptr) {
    ((id (*)(id, SEL))objc_msgSend)(browser, sel_registerName("reload"));
  }
#elif defined(__linux__)
  auto *browser = static_cast<WebKitWebView *>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER));
  if (browser != nullptr) webkit_web_view_reload(browser);
#else
  (void)native;
  end_call(state);
  raise_error("webview_reload", WEBVIEW_ERROR_MISSING_DEPENDENCY,
              "reload is unavailable on this backend");
#endif
  end_call(state);
  CAMLreturn(Val_unit);
}

OWV_FFI2(ocaml_webview_on_close, "webview_on_close", handle, closure) {
  CAMLparam2(handle, closure);
  managed_webview *state = get_state(handle, "webview_on_close");
  if (!is_owner_thread(state))
    raise_error("webview_on_close", OWV_ERROR_WRONG_THREAD);
  if (state->close_root_registered)
    raise_error("webview_on_close", WEBVIEW_ERROR_DUPLICATE,
                "a close handler is already installed");
  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) raise_error("webview_on_close", status);
#if !defined(__APPLE__) && !defined(__linux__)
  end_call(state);
  raise_error("webview_on_close", WEBVIEW_ERROR_MISSING_DEPENDENCY,
              "native close notifications are unavailable on this backend");
#endif
  state->close_closure = closure;
  caml_register_generational_global_root(&state->close_closure);
  state->close_root_registered = true;
#if defined(__APPLE__)
  id observer = ((id (*)(Class, SEL))objc_msgSend)(close_observer_class(),
                                                   sel_registerName("new"));
  associate_state(observer, &close_state_key, state);
  id center = ((id (*)(Class, SEL))objc_msgSend)(
      objc_getClass("NSNotificationCenter"),
      sel_registerName("defaultCenter"));
  id name = ((id (*)(Class, SEL, const char *))objc_msgSend)(
      objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"),
      "NSWindowWillCloseNotification");
  id window = static_cast<id>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW));
  ((void (*)(id, SEL, id, SEL, id, id))objc_msgSend)(
      center, sel_registerName("addObserver:selector:name:object:"), observer,
      sel_registerName("windowWillClose:"), name, window);
  state->close_observer = observer;
#elif defined(__linux__)
  auto *window = static_cast<GtkWidget *>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW));
#if GTK_MAJOR_VERSION >= 4
  state->close_signal = g_signal_connect_after(
      window, "close-request",
      G_CALLBACK(+[](GtkWindow *, gpointer data) -> gboolean {
        notify_window_closed(static_cast<managed_webview *>(data));
        return FALSE;
      }),
      state);
#else
  state->close_signal = g_signal_connect(
      window, "destroy",
      G_CALLBACK(+[](GtkWidget *, gpointer data) {
        notify_window_closed(static_cast<managed_webview *>(data));
      }),
      state);
#endif
#endif
  end_call(state);
  CAMLreturn(Val_unit);
}

OWV_FFI2(ocaml_webview_set_close_handler, "webview_set_close_handler", handle,
         closure) {
  CAMLparam2(handle, closure);
  managed_webview *state = get_state(handle, "webview_set_close_handler");
  if (!is_owner_thread(state))
    raise_error("webview_set_close_handler", OWV_ERROR_WRONG_THREAD);
  if (state->close_request_root_registered)
    raise_error("webview_set_close_handler", WEBVIEW_ERROR_DUPLICATE,
                "a close interception handler is already installed");
  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK)
    raise_error("webview_set_close_handler", status);
#if !defined(__APPLE__) && !defined(__linux__)
  end_call(state);
  raise_error("webview_set_close_handler", WEBVIEW_ERROR_MISSING_DEPENDENCY,
              "native close interception is unavailable on this backend");
#endif
  state->close_request_closure = closure;
  caml_register_generational_global_root(&state->close_request_closure);
  state->close_request_root_registered = true;
#if defined(__APPLE__)
  id window = static_cast<id>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW));
  associate_state(window, &close_request_state_key, state);
  Class delegate_class = objc_lookUpClass("WebviewNSWindowDelegate");
  if (delegate_class == nullptr) {
    end_call(state);
    raise_error("webview_set_close_handler", WEBVIEW_ERROR_INVALID_STATE,
                "native window delegate is unavailable");
  }
  class_addMethod(
      delegate_class, sel_registerName("windowShouldClose:"),
      reinterpret_cast<IMP>(+[](id, SEL, id window) -> bool {
        auto *state = associated_state(window, &close_request_state_key);
        return state == nullptr || should_close_window(state);
      }),
      "c@:@");
#elif defined(__linux__)
  auto *window = static_cast<GtkWidget *>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW));
#if GTK_MAJOR_VERSION >= 4
  state->close_request_signal = g_signal_connect(
      window, "close-request",
      G_CALLBACK(+[](GtkWindow *, gpointer data) -> gboolean {
        return should_close_window(static_cast<managed_webview *>(data))
                   ? FALSE
                   : TRUE;
      }),
      state);
#else
  state->close_request_signal = g_signal_connect(
      window, "delete-event",
      G_CALLBACK(+[](GtkWidget *, GdkEvent *, gpointer data) -> gboolean {
        return should_close_window(static_cast<managed_webview *>(data))
                   ? FALSE
                   : TRUE;
      }),
      state);
#endif
#endif
  end_call(state);
  CAMLreturn(Val_unit);
}

OWV_FFI2(ocaml_webview_set_navigation_handler,
         "webview_set_navigation_handler", handle, closure) {
  CAMLparam2(handle, closure);
  managed_webview *state = get_state(handle, "webview_set_navigation_handler");
  if (!is_owner_thread(state))
    raise_error("webview_set_navigation_handler", OWV_ERROR_WRONG_THREAD);
  if (state->navigation_root_registered)
    raise_error("webview_set_navigation_handler", WEBVIEW_ERROR_DUPLICATE,
                "a navigation handler is already installed");
  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK)
    raise_error("webview_set_navigation_handler", status);
#if !defined(__APPLE__) && !defined(__linux__)
  end_call(state);
  raise_error("webview_set_navigation_handler", WEBVIEW_ERROR_MISSING_DEPENDENCY,
              "native navigation policy is unavailable on this backend");
#endif
  state->navigation_closure = closure;
  caml_register_generational_global_root(&state->navigation_closure);
  state->navigation_root_registered = true;
#if defined(__APPLE__)
  id delegate = ((id (*)(Class, SEL))objc_msgSend)(navigation_delegate_class(),
                                                   sel_registerName("new"));
  associate_state(delegate, &navigation_state_key, state);
  id browser = static_cast<id>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER));
  ((void (*)(id, SEL, id))objc_msgSend)(
      browser, sel_registerName("setNavigationDelegate:"), delegate);
  state->navigation_delegate = delegate;
#elif defined(__linux__)
  auto *browser = static_cast<WebKitWebView *>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER));
  state->navigation_signal = g_signal_connect(
      browser, "decide-policy",
      G_CALLBACK(+[](WebKitWebView *, WebKitPolicyDecision *policy,
                     WebKitPolicyDecisionType type, gpointer data) -> gboolean {
        if (type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION &&
            type != WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION)
          return FALSE;
        auto *navigation = WEBKIT_NAVIGATION_POLICY_DECISION(policy);
        WebKitURIRequest *request =
            webkit_navigation_policy_decision_get_request(navigation);
        const char *uri = webkit_uri_request_get_uri(request);
        int decision =
            navigation_decision(static_cast<managed_webview *>(data), uri);
        if (decision == 0) {
          webkit_policy_decision_use(policy);
        } else {
          if (decision == 2 && uri != nullptr) open_external_url(uri);
          webkit_policy_decision_ignore(policy);
        }
        return TRUE;
      }),
      state);
#endif
  end_call(state);
  CAMLreturn(Val_unit);
}

OWV_FFI1(ocaml_webview_open_external, "open_external", url) {
  CAMLparam1(url);
  if (!open_external_url(String_val(url)))
    raise_error("open_external", WEBVIEW_ERROR_UNSPECIFIED,
                "the operating system could not open the URL");
  CAMLreturn(Val_unit);
}

OWV_FFI2(ocaml_webview_window_command, "window_command", handle, command) {
  CAMLparam2(handle, command);
  managed_webview *state = get_state(handle, "window_command");
  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) raise_error("window_command", status);
  int operation = Int_val(command);
#if defined(__APPLE__)
  id window = static_cast<id>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW));
  switch (operation) {
    case 0:
    case 2:
      ((void (*)(id, SEL, id))objc_msgSend)(
          window, sel_registerName("makeKeyAndOrderFront:"), nullptr);
      break;
    case 1:
      ((void (*)(id, SEL, id))objc_msgSend)(window,
                                            sel_registerName("orderOut:"),
                                            nullptr);
      break;
    case 3:
      ((void (*)(id, SEL, id))objc_msgSend)(window,
                                            sel_registerName("miniaturize:"),
                                            nullptr);
      break;
    case 4:
      if (!((bool (*)(id, SEL))objc_msgSend)(window,
                                             sel_registerName("isZoomed")))
        ((void (*)(id, SEL, id))objc_msgSend)(window,
                                              sel_registerName("zoom:"),
                                              nullptr);
      break;
    case 5:
      if (((bool (*)(id, SEL))objc_msgSend)(window,
                                            sel_registerName("isMiniaturized")))
        ((void (*)(id, SEL, id))objc_msgSend)(
            window, sel_registerName("deminiaturize:"), nullptr);
      if (((bool (*)(id, SEL))objc_msgSend)(window,
                                            sel_registerName("isZoomed")))
        ((void (*)(id, SEL, id))objc_msgSend)(window,
                                              sel_registerName("zoom:"),
                                              nullptr);
      break;
    case 6:
    case 7: {
      unsigned long style = ((unsigned long (*)(id, SEL))objc_msgSend)(
          window, sel_registerName("styleMask"));
      bool fullscreen = (style & (1UL << 14U)) != 0;
      if ((operation == 6 && !fullscreen) || (operation == 7 && fullscreen))
        schedule_cocoa_window_action(window, 2);
      break;
    }
    case 8: {
      dialog_state *dialog = retain_pending_dialog(state);
      if (dialog == nullptr) {
        schedule_cocoa_window_action(window, 0);
      } else {
        dialog->close_after_completion.store(true, std::memory_order_release);
        request_cocoa_dialog_cancel(dialog);
        invoke_dialog_completion_with_runtime(
            dialog, OWV_ERROR_CLOSING,
            "window close requested while native dialog was active", {});
        release_dialog_state(dialog);
      }
      break;
    }
    default: break;
  }
#elif defined(__linux__)
  auto *window = static_cast<GtkWindow *>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW));
  switch (operation) {
    case 0: gtk_widget_show(GTK_WIDGET(window)); break;
    case 1: gtk_widget_hide(GTK_WIDGET(window)); break;
    case 2:
      gtk_window_present(window);
      break;
    case 3:
#if GTK_MAJOR_VERSION >= 4
      gtk_window_minimize(window);
#else
      gtk_window_iconify(window);
#endif
      break;
    case 4: gtk_window_maximize(window); break;
    case 5:
#if GTK_MAJOR_VERSION >= 4
      gtk_window_unminimize(window);
#else
      gtk_window_deiconify(window);
#endif
      gtk_window_unmaximize(window);
      break;
    case 6: gtk_window_fullscreen(window); break;
    case 7: gtk_window_unfullscreen(window); break;
    case 8:
      g_idle_add_full(
          G_PRIORITY_HIGH_IDLE,
          +[](gpointer data) -> gboolean {
            gtk_window_close(static_cast<GtkWindow *>(data));
            return G_SOURCE_REMOVE;
          },
          window, nullptr);
      break;
    default: break;
  }
#else
  (void)operation;
  end_call(state);
  raise_error("window_command", WEBVIEW_ERROR_MISSING_DEPENDENCY,
              "native window commands are unavailable on this backend");
#endif
  end_call(state);
  CAMLreturn(Val_unit);
}

OWV_FFI3(ocaml_webview_set_position, "set_position", handle, x, y) {
  CAMLparam3(handle, x, y);
  managed_webview *state = get_state(handle, "set_position");
  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) raise_error("set_position", status);
#if defined(__APPLE__)
  id window = static_cast<id>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW));
  CGPoint point = CGPointMake(Int_val(x), Int_val(y));
  ((void (*)(id, SEL, CGPoint))objc_msgSend)(
      window, sel_registerName("setFrameOrigin:"), point);
#elif defined(__linux__)
#if GTK_MAJOR_VERSION < 4
  auto *window = static_cast<GtkWindow *>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW));
  gtk_window_move(window, Int_val(x), Int_val(y));
#else
  (void)native;
  (void)x;
  (void)y;
  end_call(state);
  raise_error("set_position", WEBVIEW_ERROR_MISSING_DEPENDENCY,
              "absolute window positioning is unavailable with GTK4");
#endif
#else
  (void)x;
  (void)y;
  end_call(state);
  raise_error("set_position", WEBVIEW_ERROR_MISSING_DEPENDENCY,
              "absolute window positioning is unavailable on this backend");
#endif
  end_call(state);
  CAMLreturn(Val_unit);
}

OWV_FFI1(ocaml_webview_system_theme, "system_theme", handle) {
  CAMLparam1(handle);
  managed_webview *state = get_state(handle, "system_theme");
  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) raise_error("system_theme", status);
  int theme = system_theme_value();
  (void)native;
  end_call(state);
  CAMLreturn(Val_int(theme));
}

OWV_FFI2(ocaml_webview_on_theme_change, "on_theme_change", handle, closure) {
  CAMLparam2(handle, closure);
  managed_webview *state = get_state(handle, "on_theme_change");
  if (!is_owner_thread(state))
    raise_error("on_theme_change", OWV_ERROR_WRONG_THREAD);
  if (state->theme_root_registered)
    raise_error("on_theme_change", WEBVIEW_ERROR_DUPLICATE,
                "a theme handler is already installed");
  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) raise_error("on_theme_change", status);
  state->theme_closure = closure;
  caml_register_generational_global_root(&state->theme_closure);
  state->theme_root_registered = true;
  bool supported = true;
#if defined(__APPLE__)
  id observer = ((id (*)(Class, SEL))objc_msgSend)(theme_observer_class(),
                                                   sel_registerName("new"));
  associate_state(observer, &theme_state_key, state);
  id center = ((id (*)(Class, SEL))objc_msgSend)(
      objc_getClass("NSDistributedNotificationCenter"),
      sel_registerName("defaultCenter"));
  id name = ((id (*)(Class, SEL, const char *))objc_msgSend)(
      objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"),
      "AppleInterfaceThemeChangedNotification");
  ((void (*)(id, SEL, id, SEL, id, id))objc_msgSend)(
      center, sel_registerName("addObserver:selector:name:object:"), observer,
      sel_registerName("themeChanged:"), name, nullptr);
  state->theme_observer = observer;
#elif defined(__linux__)
  GtkSettings *settings = gtk_settings_get_default();
  if (settings == nullptr) {
    supported = false;
  } else {
    state->theme_signal = g_signal_connect(
        settings, "notify::gtk-theme-name",
        G_CALLBACK(+[](GObject *, GParamSpec *, gpointer data) {
          notify_theme_changed(static_cast<managed_webview *>(data));
        }),
        state);
  }
#else
  (void)native;
  supported = false;
#endif
  end_call(state);
  if (!supported) {
    caml_remove_generational_global_root(&state->theme_closure);
    state->theme_root_registered = false;
    state->theme_closure = Val_unit;
    raise_error("on_theme_change", WEBVIEW_ERROR_MISSING_DEPENDENCY,
                "native theme notifications are unavailable on this backend");
  }
  CAMLreturn(Val_unit);
}

OWV_FFI3(ocaml_webview_dialog_async, "native_dialog", handle, request,
         completion) {
  CAMLparam3(handle, request, completion);
  managed_webview *state = get_state(handle, "native_dialog");
  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) raise_error("native_dialog", status);
  std::vector<std::string> paths;
  int dialog_kind = Int_val(Field(request, 0));
  const char *title = String_val(Field(request, 1));
  const char *detail = String_val(Field(request, 2));
  if (dialog_kind < 0 || dialog_kind > 4) {
    end_call(state);
    raise_error("native_dialog", WEBVIEW_ERROR_INVALID_ARGUMENT,
                "unknown native dialog kind");
  }
  bool dialog_supported = true;
#if defined(__APPLE__)
  id parent = cocoa_window_for_dialog(native);
  if (parent == nullptr) {
    end_call(state);
    raise_error("native_dialog", WEBVIEW_ERROR_INVALID_STATE,
                "native dialog has no parent window");
  }
  bool duplicate = false;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    duplicate = state->pending_dialog != nullptr;
  }
  if (duplicate) {
    end_call(state);
    raise_error("native_dialog", WEBVIEW_ERROR_DUPLICATE,
                "a native dialog is already active for this window");
  }

  auto *dialog = new (std::nothrow) dialog_state();
  if (dialog == nullptr) {
    end_call(state);
    raise_error("native_dialog", OWV_ERROR_OUT_OF_MEMORY);
  }
  try {
    dialog->title = title;
    dialog->detail = detail;
  } catch (...) {
    delete dialog;
    end_call(state);
    throw;
  }
  dialog->owner = state;
  dialog->kind = dialog_kind;
  dialog->completion = completion;
  dialog->handle = handle;
  dialog->parent = parent;
  ((id (*)(id, SEL))objc_msgSend)(parent, sel_registerName("retain"));
  caml_register_generational_global_root(&dialog->completion);
  dialog->completion_root_registered = true;
  caml_register_generational_global_root(&dialog->handle);
  dialog->handle_root_registered = true;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->pending_dialog = dialog;
  }
  dispatch_async_f(dispatch_get_main_queue(), dialog, present_cocoa_dialog);
  end_call(state);
  CAMLreturn(Val_unit);
#elif defined(__linux__) && GTK_MAJOR_VERSION < 4
  auto *parent = static_cast<GtkWindow *>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW));
  if (dialog_kind == 0) {
    GtkWidget *dialog = gtk_message_dialog_new(
        parent, GTK_DIALOG_MODAL, GTK_MESSAGE_INFO, GTK_BUTTONS_OK, "%s", detail);
    gtk_window_set_title(GTK_WINDOW(dialog), title);
    gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
  } else {
    GtkFileChooserAction action = dialog_kind == 3
                                      ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER
                                      : dialog_kind == 4
                                            ? GTK_FILE_CHOOSER_ACTION_SAVE
                                            : GTK_FILE_CHOOSER_ACTION_OPEN;
    GtkWidget *dialog = gtk_file_chooser_dialog_new(
        title, parent, action, "Cancel", GTK_RESPONSE_CANCEL,
        dialog_kind == 4 ? "Save" : "Open", GTK_RESPONSE_ACCEPT, nullptr);
    auto *chooser = GTK_FILE_CHOOSER(dialog);
    gtk_file_chooser_set_select_multiple(chooser, dialog_kind == 2);
    if (dialog_kind == 4 && detail[0] != '\0')
      gtk_file_chooser_set_current_name(chooser, detail);
    if (gtk_dialog_run(GTK_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
      GSList *selected = gtk_file_chooser_get_filenames(chooser);
      for (GSList *cursor = selected; cursor != nullptr; cursor = cursor->next) {
        char *path = static_cast<char *>(cursor->data);
        if (path != nullptr) paths.emplace_back(path);
        g_free(path);
      }
      g_slist_free(selected);
    }
    gtk_widget_destroy(dialog);
  }
#elif defined(__linux__)
  (void)native;
  (void)dialog_kind;
  dialog_supported = false;
#else
  (void)native;
  (void)dialog_kind;
  dialog_supported = false;
#endif
  end_call(state);
  if (!dialog_supported) {
    raise_error("native_dialog", WEBVIEW_ERROR_MISSING_DEPENDENCY,
                "native dialogs are unavailable on this backend");
  }
  dialog_state callback;
  callback.completion = completion;
  invoke_dialog_completion_with_runtime(&callback, WEBVIEW_ERROR_OK, "", paths);
  CAMLreturn(Val_unit);
}

OWV_FFI1(ocaml_webview_cancel_dialog, "cancel_native_dialog", handle) {
  CAMLparam1(handle);
  managed_webview *state = get_state(handle, "cancel_native_dialog");
  if (!is_owner_thread(state)) {
    raise_error("cancel_native_dialog", OWV_ERROR_WRONG_THREAD);
  }
#if defined(__APPLE__)
  dialog_state *dialog = retain_pending_dialog(state);
  if (dialog != nullptr) {
    request_cocoa_dialog_cancel(dialog);
    release_dialog_state(dialog);
  }
#else
  (void)state;
#endif
  CAMLreturn(Val_unit);
}

OWV_FFI1(ocaml_webview_platform_backend, "platform_backend", unit) {
  CAMLparam1(unit);
#if defined(OWV_BACKEND_COCOA)
  CAMLreturn(Val_int(0));
#elif defined(OWV_WEBKITGTK_6_0)
  CAMLreturn(Val_int(1));
#elif defined(OWV_WEBKITGTK_4_1)
  CAMLreturn(Val_int(2));
#elif defined(OWV_WEBKITGTK_4_0)
  CAMLreturn(Val_int(3));
#elif defined(OWV_BACKEND_WEBVIEW2)
  CAMLreturn(Val_int(4));
#else
  CAMLreturn(Val_int(5));
#endif
}

OWV_FFI1(ocaml_webview_clipboard_read, "clipboard_read", handle) {
  CAMLparam1(handle);
  CAMLlocal2(result, text);
  managed_webview *state = get_state(handle, "clipboard_read");
  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) raise_error("clipboard_read", status);
  const char *contents = nullptr;
  std::string copied;
#if defined(__APPLE__)
  id pasteboard = ((id (*)(Class, SEL))objc_msgSend)(
      objc_getClass("NSPasteboard"), sel_registerName("generalPasteboard"));
  id type = ((id (*)(Class, SEL, const char *))objc_msgSend)(
      objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"),
      "public.utf8-plain-text");
  id pasteboard_value = ((id (*)(id, SEL, id))objc_msgSend)(
      pasteboard, sel_registerName("stringForType:"), type);
  if (pasteboard_value != nullptr) {
    contents = ((const char *(*)(id, SEL))objc_msgSend)(
        pasteboard_value, sel_registerName("UTF8String"));
  }
#elif defined(__linux__) && GTK_MAJOR_VERSION < 4
  GtkClipboard *clipboard =
      gtk_clipboard_get_for_display(gdk_display_get_default(),
                                    GDK_SELECTION_CLIPBOARD);
  gchar *value = gtk_clipboard_wait_for_text(clipboard);
  if (value != nullptr) {
    copied = value;
    g_free(value);
    contents = copied.c_str();
  }
#elif defined(_WIN32)
  if (OpenClipboard(nullptr)) {
    HANDLE data = GetClipboardData(CF_UNICODETEXT);
    if (data != nullptr) {
      const wchar_t *wide = static_cast<const wchar_t *>(GlobalLock(data));
      if (wide != nullptr) {
        int size = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0,
                                       nullptr, nullptr);
        if (size > 1) {
          copied.resize(static_cast<std::size_t>(size));
          WideCharToMultiByte(CP_UTF8, 0, wide, -1, copied.data(), size,
                              nullptr, nullptr);
          copied.pop_back();
          contents = copied.c_str();
        }
        GlobalUnlock(data);
      }
    }
    CloseClipboard();
  }
#else
  (void)native;
#endif
  end_call(state);
  if (contents == nullptr) {
    CAMLreturn(Val_none);
  }
  text = caml_copy_string(contents);
  result = caml_alloc_small(1, 0);
  Store_field(result, 0, text);
  CAMLreturn(result);
}

OWV_FFI2(ocaml_webview_clipboard_write, "clipboard_write", handle, contents) {
  CAMLparam2(handle, contents);
  managed_webview *state = get_state(handle, "clipboard_write");
  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) raise_error("clipboard_write", status);
  bool supported = true;
#if defined(__APPLE__)
  id pasteboard = ((id (*)(Class, SEL))objc_msgSend)(
      objc_getClass("NSPasteboard"), sel_registerName("generalPasteboard"));
  id type = ((id (*)(Class, SEL, const char *))objc_msgSend)(
      objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"),
      "public.utf8-plain-text");
  id pasteboard_value = ((id (*)(Class, SEL, const char *))objc_msgSend)(
      objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"),
      String_val(contents));
  ((long (*)(id, SEL))objc_msgSend)(pasteboard,
                                    sel_registerName("clearContents"));
  ((bool (*)(id, SEL, id, id))objc_msgSend)(
      pasteboard, sel_registerName("setString:forType:"), pasteboard_value,
      type);
#elif defined(__linux__) && GTK_MAJOR_VERSION < 4
  GtkClipboard *clipboard =
      gtk_clipboard_get_for_display(gdk_display_get_default(),
                                    GDK_SELECTION_CLIPBOARD);
  gtk_clipboard_set_text(clipboard, String_val(contents), -1);
  gtk_clipboard_store(clipboard);
#elif defined(__linux__) && GTK_MAJOR_VERSION >= 4
  GdkDisplay *display = gdk_display_get_default();
  if (display == nullptr) {
    supported = false;
  } else {
    gdk_clipboard_set_text(gdk_display_get_clipboard(display),
                           String_val(contents));
  }
#elif defined(_WIN32)
  int wide_size = MultiByteToWideChar(CP_UTF8, 0, String_val(contents), -1,
                                      nullptr, 0);
  if (wide_size <= 0 || !OpenClipboard(nullptr)) {
    supported = false;
  } else {
    EmptyClipboard();
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE,
                                 static_cast<SIZE_T>(wide_size) * sizeof(wchar_t));
    if (memory == nullptr) {
      supported = false;
    } else {
      auto *wide = static_cast<wchar_t *>(GlobalLock(memory));
      MultiByteToWideChar(CP_UTF8, 0, String_val(contents), -1, wide,
                          wide_size);
      GlobalUnlock(memory);
      if (SetClipboardData(CF_UNICODETEXT, memory) == nullptr) {
        GlobalFree(memory);
        supported = false;
      }
    }
    CloseClipboard();
  }
#else
  (void)native;
  supported = false;
#endif
  end_call(state);
  if (!supported) {
    raise_error("clipboard_write", WEBVIEW_ERROR_MISSING_DEPENDENCY,
                "clipboard access is unavailable on this backend");
  }
  CAMLreturn(Val_unit);
}

OWV_FFI2(ocaml_webview_dispatch, "webview_dispatch", handle, closure) {
  CAMLparam2(handle, closure);
  managed_webview *state = get_state(handle, "webview_dispatch");
  auto *dispatch = new (std::nothrow) dispatch_state();
  if (dispatch == nullptr) raise_error("webview_dispatch", OWV_ERROR_OUT_OF_MEMORY);
  dispatch->owner = state;
  dispatch->closure = closure;
  dispatch->handle = handle;
  caml_register_generational_global_root(&dispatch->closure);
  dispatch->closure_root_registered = true;
  caml_register_generational_global_root(&dispatch->handle);
  dispatch->handle_root_registered = true;

  bool tracked = true;
  char exception_message[256] = {};
  try {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->all_dispatches.push_back(dispatch);
  } catch (const std::exception &exception) {
    std::snprintf(exception_message, sizeof(exception_message), "%s",
                  exception.what());
    tracked = false;
  }
  if (!tracked) {
    unregister_dispatch_roots(dispatch);
    delete dispatch;
    raise_error("webview_dispatch", OWV_ERROR_CPP_EXCEPTION, exception_message);
  }

  webview_t native = nullptr;
  int status = begin_call(state, false, &native);
  if (status != WEBVIEW_ERROR_OK) {
    unregister_dispatch_roots(dispatch);
    dispatch->completed.store(true, std::memory_order_release);
    raise_error("webview_dispatch", status);
  }
  webview_error_t error = webview_dispatch(native, dispatch_trampoline, dispatch);
  end_call(state);
  if (error != WEBVIEW_ERROR_OK) {
    unregister_dispatch_roots(dispatch);
    dispatch->completed.store(true, std::memory_order_release);
    check_error("webview_dispatch", error);
  }
  CAMLreturn(Val_unit);
}

OWV_FFI2(ocaml_webview_defer, "webview_defer", handle, closure) {
  CAMLparam2(handle, closure);
  managed_webview *state = get_state(handle, "webview_defer");
  if (!is_owner_thread(state))
    raise_error("webview_defer", OWV_ERROR_WRONG_THREAD);

  auto *dispatch = new (std::nothrow) dispatch_state();
  if (dispatch == nullptr) raise_error("webview_defer", OWV_ERROR_OUT_OF_MEMORY);
  dispatch->owner = state;
  dispatch->closure = closure;
  dispatch->handle = handle;
  caml_register_generational_global_root(&dispatch->closure);
  dispatch->closure_root_registered = true;
  caml_register_generational_global_root(&dispatch->handle);
  dispatch->handle_root_registered = true;

  bool tracked = true;
  char exception_message[256] = {};
  try {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->all_dispatches.push_back(dispatch);
  } catch (const std::exception &exception) {
    std::snprintf(exception_message, sizeof(exception_message), "%s",
                  exception.what());
    tracked = false;
  }
  if (!tracked) {
    unregister_dispatch_roots(dispatch);
    delete dispatch;
    raise_error("webview_defer", OWV_ERROR_CPP_EXCEPTION, exception_message);
  }

  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) {
    unregister_dispatch_roots(dispatch);
    dispatch->completed.store(true, std::memory_order_release);
    raise_error("webview_defer", status);
  }

  bool scheduled = true;
#if defined(__APPLE__)
  CFRunLoopTimerContext context = {0, dispatch, nullptr, nullptr, nullptr};
  CFRunLoopTimerRef timer =
      CFRunLoopTimerCreate(nullptr, CFAbsoluteTimeGetCurrent(), 0.0, 0, 0,
                           deferred_dispatch_timer, &context);
  if (timer == nullptr) {
    scheduled = false;
  } else {
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
    CFRelease(timer);
  }
#elif defined(__linux__)
  scheduled = g_timeout_add_full(G_PRIORITY_HIGH, 0, deferred_dispatch_idle,
                                 dispatch, nullptr) != 0;
#else
  scheduled =
      webview_dispatch(native, dispatch_trampoline, dispatch) == WEBVIEW_ERROR_OK;
#endif
  end_call(state);
  if (!scheduled) {
    unregister_dispatch_roots(dispatch);
    dispatch->completed.store(true, std::memory_order_release);
    raise_error("webview_defer", WEBVIEW_ERROR_UNSPECIFIED,
                "could not schedule a native run-loop callback");
  }
  CAMLreturn(Val_unit);
}

OWV_FFI1(ocaml_webview_version, "webview_version", unit) {
  CAMLparam1(unit);
  CAMLlocal2(info, field);
  const webview_version_info_t *version = webview_version();
  info = caml_alloc_tuple(6);
  Store_field(info, 0, Val_int(version->version.major));
  Store_field(info, 1, Val_int(version->version.minor));
  Store_field(info, 2, Val_int(version->version.patch));
  field = caml_copy_string(version->version_number);
  Store_field(info, 3, field);
  field = caml_copy_string(version->pre_release);
  Store_field(info, 4, field);
  field = caml_copy_string(version->build_metadata);
  Store_field(info, 5, field);
  CAMLreturn(info);
}

OWV_FFI1(ocaml_webview_get_window, "webview_get_window", handle) {
  CAMLparam1(handle);
  managed_webview *state = get_state(handle, "webview_get_window");
  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) raise_error("webview_get_window", status);
  void *window = webview_get_window(native);
  end_call(state);
  CAMLreturn(caml_copy_nativeint(reinterpret_cast<intnat>(window)));
}

OWV_FFI2(ocaml_webview_get_native_handle, "webview_get_native_handle", handle,
         kind) {
  CAMLparam2(handle, kind);
  managed_webview *state = get_state(handle, "webview_get_native_handle");
  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) raise_error("webview_get_native_handle", status);
  void *native_handle = webview_get_native_handle(native, native_handle_kind(kind));
  end_call(state);
  CAMLreturn(caml_copy_nativeint(reinterpret_cast<intnat>(native_handle)));
}

OWV_FFI2(ocaml_webview_set_app_icon, "set_app_icon", handle, path) {
  CAMLparam2(handle, path);
  managed_webview *state = get_state(handle, "set_app_icon");
  webview_t native = nullptr;
  int status = begin_call(state, true, &native);
  if (status != WEBVIEW_ERROR_OK) raise_error("set_app_icon", status);
  const char *native_path = String_val(path);
  const char *failure = nullptr;
#if defined(__APPLE__)
  id app = ((id (*)(Class, SEL))objc_msgSend)(
      objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
  id ns_path = ((id (*)(Class, SEL, const char *))objc_msgSend)(
      objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), native_path);
  id image = ((id (*)(Class, SEL))objc_msgSend)(objc_getClass("NSImage"),
                                                sel_registerName("alloc"));
  image = ((id (*)(id, SEL, id))objc_msgSend)(
      image, sel_registerName("initWithContentsOfFile:"), ns_path);
  if (image == nullptr) {
    failure = "could not load image file";
  } else {
    ((void (*)(id, SEL, id))objc_msgSend)(
        app, sel_registerName("setApplicationIconImage:"), image);
    ((void (*)(id, SEL))objc_msgSend)(image, sel_registerName("release"));
  }
#elif defined(__linux__) && GTK_MAJOR_VERSION < 4
  char failure_message[256] = {};
  GtkWindow *window = static_cast<GtkWindow *>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW));
  GError *error = nullptr;
  if (window == nullptr || !gtk_window_set_icon_from_file(window, native_path, &error)) {
    std::snprintf(failure_message, sizeof(failure_message), "%s",
                  error != nullptr && error->message != nullptr
                      ? error->message
                      : "could not load image file");
    failure = failure_message;
    if (error != nullptr) g_error_free(error);
  }
#elif defined(__linux__) && GTK_MAJOR_VERSION >= 4
  (void)native;
  (void)native_path;
  failure = "window icons require application metadata on GTK4";
#elif defined(_WIN32)
  HWND window = static_cast<HWND>(webview_get_native_handle(
      native, WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW));
  HANDLE icon = LoadImageA(nullptr, native_path, IMAGE_ICON, 0, 0,
                           LR_LOADFROMFILE | LR_DEFAULTSIZE);
  if (window == nullptr || icon == nullptr) {
    failure = "could not load icon; Windows expects an .ico file";
  } else {
    SendMessageW(window, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(icon));
    SendMessageW(window, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(icon));
  }
#else
  (void)native;
  (void)native_path;
#endif
  end_call(state);
  if (failure != nullptr) raise_error("set_app_icon", WEBVIEW_ERROR_UNSPECIFIED, failure);
  CAMLreturn(Val_unit);
}

#undef OWV_FFI1
#undef OWV_FFI2
#undef OWV_FFI3
#undef OWV_FFI4

}  // extern "C"
