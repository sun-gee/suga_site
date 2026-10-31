#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // The window fits the app's content: 520 wide (the content's maximum width, so no empty side margins) and tall
  // enough that the Practice page never scrolls, even with SugAmen Groove and Speed Up both on (the tallest it
  // gets). Re-measure if the Practice page grows. On a shorter screen it fills the height and scrolls.
  // Sizes are in logical pixels; the window is centred in the primary screen's work area.
  const int content_width = 520;
  const int content_height = 965;
  RECT frame = {0, 0, content_width, content_height};
  ::AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW, FALSE, 0, 96);  // Add the title bar and borders
  RECT work_area;
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0);
  const double scale = ::GetDpiForSystem() / 96.0;
  const int work_left = static_cast<int>(work_area.left / scale);
  const int work_top = static_cast<int>(work_area.top / scale);
  const int work_width = static_cast<int>((work_area.right - work_area.left) / scale);
  const int work_height = static_cast<int>((work_area.bottom - work_area.top) / scale);
  const int width = frame.right - frame.left;
  const int height = work_height < frame.bottom - frame.top ? work_height : frame.bottom - frame.top;
  Win32Window::Point origin(work_left + (work_width - width) / 2, work_top + (work_height - height) / 2);
  Win32Window::Size size(width, height);
  if (!window.Create(L"Suga", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
