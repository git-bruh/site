#include <assert.h>
#include <ctype.h>
#include <curl/curl.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

void *network_thread(void *);

int notify_fd;

void notify_main(void) {
  int ret = write(notify_fd, &(char){'\0'}, 1);
  assert(ret == 1);
}
void sigwinch_handler(int sig) { notify_main(); }

void term_clear(void) { printf("\x1b[H\033[2J"); }
/* This escape sequence moves the cursor to the relevant y and x co-ordinates
 * so that we can print the output. Example usage:
 *   term_set_cursor(1, 1); // Shift to the first column of the first row
 *   printf("Hello from (1, 1)!");
 */
void term_set_cursor(int y, int x) { printf("\x1b[%d;%dH", y, x); }

struct wsize {
  int rows;
  int cols;
};

struct curl_response {
  char *response;
  size_t size;
};

struct global_state {
  /* Used to communicate the URL to be fetched to the Network thread
   * Written to by the main thread, and read by the Network thread */ 
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

static size_t write_cb(void *data, size_t size, size_t nmemb, void *clientp) {
  size_t realsize = size * nmemb;
  struct curl_response *mem = (struct curl_response *)clientp;

  char *ptr = realloc(mem->response, mem->size + realsize + 1);
  assert(ptr);

  mem->response = ptr;
  memcpy(&(mem->response[mem->size]), data, realsize);
  mem->size += realsize;
  mem->response[mem->size] = 0;

  return realsize;
}

/* The first fd on a pipe is for reading, and the other is for writing */
enum {
  READ_END = 0,
  WRITE_END = 1,
};

/* Tagged Unions for the utterly deranged */
struct pipe_event {
  char *url;
};

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

void restore_term(struct termios *original_tios) {
  tcsetattr(STDIN_FILENO, TCSAFLUSH, original_tios);

  /* Switch back to the original terminal scrollback/screen */
  printf("\033[?1049l\033[23;0;0t");
  fflush(stdout);
}

struct wsize get_win_size(void) {
  struct winsize ws;
  ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws);

  return (struct wsize){.rows = ws.ws_row, .cols = ws.ws_col};
}

void init_state(struct global_state *state) {
  curl_global_init(CURL_GLOBAL_ALL);

  *state = (struct global_state){
      .multi = curl_multi_init(),
  };

  pipe(state->pipe);
  pipe(state->notify_ui_pipe);

  fcntl(state->pipe[READ_END], F_SETFL, O_NONBLOCK);

  pthread_create(&state->network_thread, NULL, &network_thread, state);
}

void cleanup_state(struct global_state *state) {
  state->done = true;
  curl_multi_wakeup(state->multi);

  pthread_join(state->network_thread, NULL);

  /* Drain any unused events not consumed from the pipe due to premature
   * exit requested by Ctrl + C */
  for (;;) {
    struct pipe_event ev;
    int ret = read(state->pipe[READ_END], &ev, sizeof(ev));

    /* If no data is there, errno would be set to EWOULDBLOCK as read() would
     * have to wait until data is written, meaning that the pipe is already
     * drained */
    if (ret == -1 && errno == EWOULDBLOCK) {
      break;
    }

    assert(ret == sizeof(ev));
    free(ev.url);
  }

  close(state->pipe[READ_END]);
  close(state->pipe[WRITE_END]);

  close(state->notify_ui_pipe[READ_END]);
  close(state->notify_ui_pipe[WRITE_END]);

  curl_multi_cleanup(state->multi);
  curl_global_cleanup();

  for (size_t i = 0; i < 1024; i++) {
    free(state->buffer.responses[i].response);
  }
}

void *network_thread(void *arg) {
  struct global_state *state = arg;

  CURL *easy = curl_easy_init();
  assert(easy);

  struct curl_response chunk = {0};

  int prev_running_handles = -1;

  while (!state->done) {
    int running_handles;

    CURLMcode code = curl_multi_perform(state->multi, &running_handles);

    if (code != CURLM_OK) {
      break;
    }

    struct curl_waitfd pipe_waiter = {.fd = state->pipe[READ_END],
                                      .events = CURL_WAIT_POLLIN};

    /* A transfer completed/failed */
    if (prev_running_handles == 1 && running_handles == 0) {
      if (++state->buffer.latest_response == 1024) {
        assert(!"Max responses filled!");
      }

      notify_main();
    }

    int ret = curl_multi_poll(state->multi, &pipe_waiter, 1, 10000, &(int){0});

    if (ret != CURLM_OK) {
      break;
    }

    /* We only perform one request at a time here for simplicitly,
     * but still prefer the curl_multi_poll API as that allows us to
     * nearly instantly interrupt the transfer and cleanup on Ctrl + C */
    if (running_handles == 0 && pipe_waiter.revents & CURL_WAIT_POLLIN) {
      struct pipe_event read_event;

      int ret = read(state->pipe[READ_END], &read_event, sizeof(read_event));
      assert(ret == sizeof(read_event));

      curl_multi_remove_handle(state->multi, easy);
      curl_easy_setopt(easy, CURLOPT_URL, read_event.url);
      curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, write_cb);
      curl_easy_setopt(easy, CURLOPT_WRITEDATA,
                       &state->buffer.responses[state->buffer.latest_response]);
      curl_multi_add_handle(state->multi, easy);

      free(read_event.url);
    }

    prev_running_handles = running_handles;
  }

  if (!state->done) {
    assert(!"CURL returned failure without being interrupted!");
  }

  curl_multi_remove_handle(state->multi, easy);
  curl_easy_cleanup(easy);

  pthread_exit(NULL);
}

void send_request(struct global_state *state, char *buf) {
  struct pipe_event event = {
      .url = strdup(buf),
  };

  /* If the structure was larger and we wanted this to be more efficient,
   * we could allocate the struct on the heap, cast the pointer to uintptr_t
   * and pass it over the pipe */
  int ret = write(state->pipe[WRITE_END], &event, sizeof(event));
  assert(ret == sizeof(event));

  /* Wake up the reader */
  curl_multi_wakeup(state->multi);
}

static void read_char(struct global_state *state, char buf[128], char c) {
  size_t len = strlen(buf);

  switch (c) {
  /* Newline */
  case '\r':
    send_request(state, buf);
    memset(buf, 0, 128);
    break;
  /* Backspace */
  case 127:
  case '\b':
    if (len > 0) {
      buf[len - 1] = '\0';
    }
    break;
  /* Double quote scrolls down */
  case '"':
    state->scroll--;
    break;
  /* Single quote scrolls down */
  case '\'':
    state->scroll++;
    break;
  default:
    if ((len + 1) < 128 && isprint(c)) {
      buf[len] = c;
    }
  }
}

static void redraw(struct global_state *state, char *buf) {
  struct wsize size = get_win_size();

  term_clear();

  int y = size.rows - 1;

  /* Skip N lines from the bottom to provide a scrolling effect */
  int n_skip = state->scroll;

  for (size_t i = state->buffer.latest_response; i > 0; i--) {
    struct curl_response *resp = &state->buffer.responses[i - 1];

    /* Failed request */
    if (!resp->response) {
      continue;
    }

    for (size_t index = resp->size; index > 0; index--) {
      size_t start = index - 1;

      if (start == 0 || resp->response[start - 1] == '\n') {
        if (y <= 0) {
          break;
        }

        if (n_skip-- > 0) {
          continue;
        }

        char *begin = &resp->response[start];
        char *newline = strchr(begin, '\n');

        newline = newline ? newline : &resp->response[resp->size];

        /* Begin printing at the corresponding y and x co-ordinates */
        term_set_cursor(y--, 1);

        for (size_t i = 0; begin != (newline + 1) && i < size.cols;
             i++, begin++) {
          putchar(*begin == '\t' ? ' ' : *begin);
        }
      }
    }
  }

  term_set_cursor(size.rows, 1);
  printf("%.*s", size.cols, buf);

  fflush(stdout);
}

int main(void) {
  struct global_state state;
  init_state(&state);

  struct termios original_tios;
  make_term_raw(&original_tios);

  notify_fd = state.notify_ui_pipe[WRITE_END];
  sigaction(SIGWINCH,
            &(struct sigaction){
                .sa_handler = &sigwinch_handler,
            },
            NULL);

  char buf[128] = {0};

  for (;;) {
    redraw(&state, buf);

    struct pollfd fds[] = {
        {.fd = STDIN_FILENO, .events = POLL_IN},
        {.fd = state.notify_ui_pipe[READ_END], .events = POLL_IN}};

    poll(fds, 2, -1);

    if (fds[0].revents & POLL_IN) {
      char c;

      int ret = read(STDIN_FILENO, &c, 1);
      assert(ret == 1);

      /* Ctrl + C */
      if (c == 3) {
        break;
      }

      read_char(&state, buf, c);
    }

    /* SIGWINCH received or new data recevied */
    if (fds[1].revents & POLL_IN) {
      /* Nothing to do -- just redraw
       * We read() the pipe here to empty it to prevent poll() from returning
       * instantly as there would be unread data on the pipe, causing an
       * expensive infinite loop */
      int ret = read(state.notify_ui_pipe[READ_END], &(char){'\0'}, 1);
      assert(ret == 1);
    }
  }

  restore_term(&original_tios);
  cleanup_state(&state);
}
