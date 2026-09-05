#include "convert.hpp"
#include "protocol.hpp"
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XShm.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <charconv>
#include <csignal>
#include <iostream>
#include <string_view>
#include <thread>

static volatile std::sig_atomic_t stopping = 0;
static int xError = 0;
// Mark shared memory for deletion as soon as Xorg attaches. Even a broken pipe
// or SIGKILL then releases it when both processes detach; no persistent segment.
struct SharedScreen {
    Display* display = nullptr;
    XImage* image = nullptr;
    XShmSegmentInfo memory{};
    bool attached = false;
    SharedScreen() { memory.shmid = -1; memory.shmaddr = reinterpret_cast<char*>(-1); }
    ~SharedScreen() {
        if (attached) { XShmDetach(display, &memory); XSync(display, False); }
        if (image) { image->data = nullptr; XDestroyImage(image); }
        if (memory.shmaddr != reinterpret_cast<char*>(-1)) shmdt(memory.shmaddr);
        if (memory.shmid >= 0) shmctl(memory.shmid, IPC_RMID, nullptr);
        if (display) XCloseDisplay(display);
    }
};

// Capture the whole, already-resized X11 root using shared memory. Unsupported
// layouts return 75 before emitting pixels so capture.sh can use FFmpeg safely.
// A runtime capture or pipe failure instead ends the stream for USB recovery.
int main(int argc, char** argv) { try {
    if (argc != 4 && argc != 5) throw std::runtime_error("Usage: deck-capture WIDTH HEIGHT FPS [FRAMES]");
    auto number = [](std::string_view text) {
        unsigned value = 0;
        auto result = std::from_chars(text.data(), text.data()+text.size(), value);
        if (result.ec != std::errc{} || result.ptr != text.data()+text.size())
            throw std::runtime_error("Invalid capture number");
        return value;
    };
    unsigned width = number(argv[1]), height = number(argv[2]), fps = number(argv[3]);
    unsigned limit = argc == 5 ? number(argv[4]) : 0;
    auto bytes = deckusb::frameBytes(width, height, deckusb::nv12);
    if (!fps || fps > 240 || (argc == 5 && !limit)) throw std::runtime_error("Invalid capture rate or frame count");
    SharedScreen screen;
    screen.display = XOpenDisplay(nullptr);
    if (!screen.display || !XShmQueryExtension(screen.display)) return 75;
    XSetErrorHandler([](Display*, XErrorEvent* error) { xError = error->error_code; return 0; });
    Window root = DefaultRootWindow(screen.display);
    XWindowAttributes attributes{};
    if (!XGetWindowAttributes(screen.display, root, &attributes) || attributes.width != int(width) || attributes.height != int(height)) return 75;
    screen.image = XShmCreateImage(screen.display, attributes.visual, attributes.depth,
        ZPixmap, nullptr, &screen.memory, width, height);
    auto image = screen.image;
    if (!image || image->bits_per_pixel != 32 || image->byte_order != LSBFirst ||
        image->bytes_per_line != int(width*4) || image->red_mask != 0xff0000 ||
        image->green_mask != 0xff00 || image->blue_mask != 0xff) return 75;
    screen.memory.shmid = shmget(IPC_PRIVATE, size_t(image->bytes_per_line)*height, IPC_CREAT | 0600);
    if (screen.memory.shmid < 0) return 75;
    screen.memory.shmaddr = static_cast<char*>(shmat(screen.memory.shmid, nullptr, 0));
    if (screen.memory.shmaddr == reinterpret_cast<char*>(-1)) return 75;
    image->data = screen.memory.shmaddr; screen.memory.readOnly = False;
    if (!XShmAttach(screen.display, &screen.memory)) return 75;
    XSync(screen.display, False);
    if (xError) return 75;
    screen.attached = true;
    if (shmctl(screen.memory.shmid, IPC_RMID, nullptr) < 0) return 75;
    screen.memory.shmid = -1;
    // Validate one capture before committing this path to the raw output stream.
    if (!XShmGetImage(screen.display, root, image, 0, 0, AllPlanes) || xError) return 75;
    std::vector<uint8_t> output(bytes);
    std::ios::sync_with_stdio(false);
    for (int signal : {SIGTERM, SIGINT, SIGHUP}) std::signal(signal, [](int) { stopping = 1; });
    std::cerr << "Native X11 capture with vectorized CPU conversion.\n";
    auto interval = std::chrono::nanoseconds(1000000000ULL / fps);
    auto deadline = std::chrono::steady_clock::now();
    for (unsigned frame = 0; !stopping && (!limit || frame < limit); ++frame) {
        if (!XShmGetImage(screen.display, root, image, 0, 0, AllPlanes) || xError)
            throw std::runtime_error("X11 capture failed");
        deckusb::bgr0ToNV12(reinterpret_cast<const uint8_t*>(image->data), output.data(), width, height);
        if (!std::cout.write(reinterpret_cast<const char*>(output.data()), output.size()))
            throw std::runtime_error("Capture output failed");
        deadline += interval;
        auto now = std::chrono::steady_clock::now();
        if (deadline < now) deadline = now; // Skip missed deadlines, never send a catch-up burst.
        std::this_thread::sleep_until(deadline);
    }
    if (!std::cout.flush()) throw std::runtime_error("Capture output failed");
    return 0;
} catch (const std::exception& error) { std::cerr << "DeckUSB capture: " << error.what() << '\n'; return 1; } }
