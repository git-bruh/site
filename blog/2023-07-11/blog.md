# Writing an asynchronous TUI in C

In this post, we'll write a barebones TUI (<400 LOC) to learn about the machinery involved for performing asynchronous I/O, network requests, and wrangling terminals in C. Some of the topics we'll be covering are:

- The `poll` syscall

- Threads and Atomics

- Pipes

- Signals

- The `termios(3)` family of functions and some escape sequences

- libCURL

The post will just give a brief about using all these components to build a TUI, and won't be going in-depth into each of them (refer to the "Further Reading" section for that)

# Setting The Stage

By the end of this post, we'd have built a basic TUI capable of taking URLs as user input, using libCURL to fetch contents of said URLs and displaying them in a TUI. The TUI can handle reading user input, drawing the UI, handling signals, performing network requests, all in a concurrent fashion, hence we refer to it as "asynchronous". The code for it can be found [here](https://github.com/git-bruh/git-bruh.github.io/tree/master/code/async_tui).

Let's lay down the shared state for this program and correlate it with the data flow:

```c
/* User generated event passed over to the network thread via the pipe */
struct pipe_event {
  char *url;
};

struct global_state {
  /* Used to communicate the URL to be fetched to the Network thread
   * Written to by the main thread (pipe_event), and read by the Network thread */
  int pipe[2];
  /* Used to wake up the main thread to resize on SIGWINCH
   * or display new data received by the network thread
   * No actual data is transmitted over this pipe, only a dummy byte
   * is written to it to wake up the main thread's poll() syscall, making it
   * redraw the UI instantly */
  int notify_ui_pipe[2];
  /* Number of lines to skip while printing (from the bottom) */
  int scroll;
  /* Checked by the network thread to determine when to exit */
  _Atomic bool done;
  /* The libCURL handle used by the network thread to perform requests */
  CURLM *multi;
  pthread_t network_thread;
  /* This is a shared buffer (fixed size, for simplicity) that the Network
   * thread writes to, and the main thread reads from to display the TUI
   * `latest_response` is an index into the `responses` array, indicating
   * how many requests have been performed so far, and the corresponding data
   * is stored in `responses` */
  /* The flow goes something like this:
   *   main_thread -> pipe -> network_thread -> curl
   *   curl_response -> responses -> notify main thread
   * The network thread fetches the requested URL, stores it's contents in
   * the first unused index in `responses`, and once the request is finished,
   * increments `latest_response` to indicate that the new response is ready to
   * be displayed by the main thread */
  struct {
    struct curl_response responses[1024];
    _Atomic size_t latest_response;
  } buffer;
};
```

- Main Thread
  - Read User Input (URLs)
    - Wrap it in the `pipe_event` struct and pass it to the Network thread via a pipe (`pipe`)
  - Display all data fetched by the Network thread in the TUI (`buffer`)
  - Redraw the UI on terminal resize (SIGWINCH handler), or when the Network thread notifies us of new data (`notify_ui_pipe`)
  - Gracefully handle program exit, cleaning up all resources (`done`)
- Network Thread
  - Listen for user generated events on the pipe (`pipe`)
  - Fetch the requested URL via libCURL (`multi`)
  - Store fetched data in a shared buffer, and notify the main thread of the newly added data (`buffer`, `notify_ui_pipe`)

# Terminal & Input Handling

First off, we'll be setting up the terminal in a way that allows us to read input character-by-character rather than being line buffered:

```c
void make_term_raw(struct termios *original_tios) {
  struct termios raw;

  /* Get the current parameters/attributes */
  tcgetattr(STDIN_FILENO, &raw);

  /* Save the terminal attributes to restore the terminal to a sane state
   * on cleanup */
  memcpy(original_tios, &raw, sizeof(raw));

  cfmakeraw(&raw);

  /* Allow read() to return only after reading 1 character */
  raw.c_cc[VMIN] = 1;
  /* Disable timeouts for read(), allowing it to block until a character is entered */
  raw.c_cc[VTIME] = 0;

  /* TCSAFLUSH pushes the changes after all pending output has been written */
  tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);

  /* Switch to a secondary "screen", allowing us to control the scrollback
   * independently of the terminal in use */
  printf("\033[?1049h\033[22;0;0t");
  fflush(stdout);
}
```

We put the terminal in the "raw" mode to enable this behaviour, and then switch to an alternative "screen", allowing us to control how the output should be displayed, and how scrollback should be handled.

We also save the original terminal attributes in `original_tios` so that we can restore the terminal to it's original state when cleaning up:

```c
void restore_term(struct termios *original_tios) {
  tcsetattr(STDIN_FILENO, TCSAFLUSH, original_tios);

  /* Switch back to the original terminal scrollback/screen */
  printf("\033[?1049l\033[23;0;0t");
  fflush(stdout);
}
```

The terminfo capabilities used for entering/exiting the alternative "screen" are `smcup` and `rmcup`. More details on everything described here can be looked up from the resources in the "Further Reading" section.

We also want helpers to clear the screen, and move the cursor to specific positions so that we can actually write the output:

```c
void term_clear(void) { printf("\x1b[H\033[2J"); }
/* This escape sequence moves the cursor to the relevant y and x co-ordinates
 * so that we can print the output. Example usage:
 *   term_set_cursor(1, 1); // Shift to the first column of the first row
 *   printf("Hello from (1, 1)!");
 */
void term_set_cursor(int y, int x) { printf("\x1b[%d;%dH", y, x); }
```

For getting the current rows and columns available in the terminal, we can use the `TIOCGWINSZ` ioctl:

```c
struct wsize {
  int rows;
  int cols;
};

struct wsize get_win_size(void) {
  struct winsize ws;
  ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws);

  return (struct wsize){.rows = ws.ws_row, .cols = ws.ws_col};
}
```

Finally, an end-to-end usage of all these helper functions might look like this:

```c
int main(void) {

}
```

# Further Reading

Raw mode https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html

Terminfo capabilities for alternative "screen" https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-The-Alternate-Screen-Buffer
