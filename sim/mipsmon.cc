/* mipsmon.cc -- curses client for the mips-axi TCP monitor/console.
 *
 *   mipsmon [host [port]]        (default: localhost 2323)
 *
 * A full-screen ncurses front-end for the mips-axi TCP monitor/console
 * (mon.cc).  Over the old raw pipe it adds:
 *   - SCROLLBACK: all console/monitor output is kept in a ring buffer; PgUp /
 *     PgDn scroll through it.  New output stays put while scrolled; any other
 *     key jumps back to live.
 *   - COMMAND HISTORY: in LINE mode, Up/Down recall previously sent lines.
 *   - two input modes: LINE (edit a line, Enter sends it + CR, with history)
 *     and RAW (each keystroke goes straight to the SCC Rx -- needed for the
 *     login password, control chars, vi, ...).  Ctrl-R toggles.
 *
 * Keys:  Ctrl-]  toggle the server's line-monitor (state/pc/epc/regs/trace/...)
 *        Ctrl-R  toggle LINE/RAW input      Ctrl-L  redraw     Ctrl-U  clear line
 *        PgUp / PgDn  scroll                Ctrl-\  quit
 * In LINE mode, typing "quit" or "exit" also quits the client.
 */
#include <ncurses.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <deque>
#include <vector>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <netdb.h>
#include <csignal>

static const size_t MAX_SCROLLBACK = 20000;
static const size_t MAX_HISTORY    = 500;

static std::deque<std::string> g_lines;   /* completed output lines (oldest..newest) */
static std::string g_partial;             /* current unterminated output line */
static std::vector<std::string> g_hist;   /* sent-command history */
static int  g_hist_idx = -1;              /* index while navigating history, -1 = off */
static std::string g_saved_input;         /* stashed edit line while browsing history */
static std::string g_input;               /* current line being edited (LINE mode) */
static int  g_scroll = 0;                 /* screen-rows scrolled up (0 = live tail) */
static bool g_raw = false;                /* RAW char-passthrough mode */
static const char *g_host = "localhost", *g_port = "2323";

static WINDOW *g_out = nullptr, *g_status = nullptr, *g_in = nullptr;

/* Safety net for Ctrl-C pass-through: raw() should stop the terminal from turning
 * Ctrl-C into SIGINT (so it arrives as byte 0x03 below), but if some pty/ssh/tmux
 * setup still raises SIGINT, catch it here instead of dying and forward 0x03 to the
 * session from the main loop. */
static volatile sig_atomic_t g_sigint = 0;
static void on_sigint(int) { g_sigint = 1; }

static void push_line(const std::string &s) {
  g_lines.push_back(s);
  while(g_lines.size() > MAX_SCROLLBACK) {
    g_lines.pop_front();
  }
}

static void feed_output(const char *b, int n) {
  for(int i = 0; i < n; i++) {
    unsigned char c = (unsigned char)b[i];
    if(c == '\r') {
      continue;
    }
    if(c == '\n') {
      push_line(g_partial);
      g_partial.clear();
    }
    else if(c == '\t') {
      do { g_partial += ' '; } while(g_partial.size() % 8);
    }
    else if(c == 8 || c == 127) {
      if(!g_partial.empty()) { g_partial.pop_back(); }
    }
    else if(c >= 32) {
      g_partial += (char)c;
    }
    /* other control bytes are dropped from the display */
  }
}

static void wrap_into(const std::string &s, int w, std::vector<std::string> &out) {
  if(s.empty() || w <= 0) { out.push_back(std::string()); return; }
  for(size_t i = 0; i < s.size(); i += (size_t)w) {
    out.push_back(s.substr(i, (size_t)w));
  }
}

static void draw(void) {
  int rows = LINES - 2, cols = COLS;
  if(rows < 1) { rows = 1; }

  /* fetch enough tail logical lines (newest-first) to fill rows + scroll */
  size_t need = (size_t)rows + (size_t)g_scroll + 4;
  std::vector<std::string> newest_first;
  newest_first.push_back(g_partial);
  for(auto it = g_lines.rbegin(); it != g_lines.rend() && newest_first.size() < need; ++it) {
    newest_first.push_back(*it);
  }
  /* wrap oldest-first into screen rows */
  std::vector<std::string> screen;
  for(auto it = newest_first.rbegin(); it != newest_first.rend(); ++it) {
    wrap_into(*it, cols, screen);
  }

  int total = (int)screen.size();
  int max_scroll = total > rows ? total - rows : 0;
  if(g_scroll > max_scroll) { g_scroll = max_scroll; }
  int start = total - rows - g_scroll;
  if(start < 0) { start = 0; }

  werase(g_out);
  for(int r = 0; r < rows && (start + r) < total; r++) {
    mvwaddnstr(g_out, r, 0, screen[start + r].c_str(), cols);
  }
  wnoutrefresh(g_out);

  werase(g_status);
  wattron(g_status, A_REVERSE);
  char st[512];
  snprintf(st, sizeof(st),
           " mipsmon %s:%s | %s | %s | ^]mon ^Rmode ^Lredraw PgUp/Dn=scroll Up/Dn=hist ^\\quit ",
           g_host, g_port, g_raw ? "RAW " : "LINE",
           g_scroll ? "SCROLLED" : "live");
  mvwaddnstr(g_status, 0, 0, st, cols);
  for(int c = (int)strlen(st); c < cols; c++) { mvwaddch(g_status, 0, c, ' '); }
  wattroff(g_status, A_REVERSE);
  wnoutrefresh(g_status);

  werase(g_in);
  if(!g_raw) {
    std::string prompt = "> " + g_input;
    int from = ((int)prompt.size() >= cols) ? (int)prompt.size() - cols + 1 : 0;
    mvwaddnstr(g_in, 0, 0, prompt.c_str() + from, cols);
    wmove(g_in, 0, (int)prompt.size() - from);
  } else {
    mvwaddnstr(g_in, 0, 0, "[RAW mode -- keystrokes go straight to the core; ^R for LINE mode]", cols);
  }
  wnoutrefresh(g_in);
  doupdate();
}

static void send_str(int s, const std::string &b) {
  if(!b.empty()) { (void)!write(s, b.data(), b.size()); }
}
static void send_byte(int s, char c) {
  (void)!write(s, &c, 1);
}

int main(int argc, char **argv) {
  if(argc > 1) { g_host = argv[1]; }
  if(argc > 2) { g_port = argv[2]; }

  struct addrinfo hints, *res = nullptr;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  if(getaddrinfo(g_host, g_port, &hints, &res) != 0) {
    fprintf(stderr, "mipsmon: cannot resolve %s\n", g_host);
    return 1;
  }
  int s = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
  if(s < 0 || connect(s, res->ai_addr, res->ai_addrlen) < 0) {
    fprintf(stderr, "mipsmon: cannot connect to %s:%s\n", g_host, g_port);
    return 1;
  }
  freeaddrinfo(res);
  fcntl(s, F_SETFL, O_NONBLOCK);

  signal(SIGINT, on_sigint);   /* don't let a stray SIGINT kill us -- forward it (below) */

  initscr();
  raw();       /* not cbreak(): raw() disables ISIG so Ctrl-C (0x03), Ctrl-\ (0x1c)
                * etc. are delivered as bytes to wgetch() instead of raising SIGINT/
                * SIGQUIT and killing mipsmon.  Ctrl-C is then passed through to the
                * underlying session; mipsmon's own control keys are still handled
                * explicitly below (Ctrl-\ quit, Ctrl-] mon, Ctrl-R mode, ...). */
  noecho();
  keypad(stdscr, TRUE);
  nonl();
  g_out    = newwin(LINES - 2, COLS, 0, 0);
  g_status = newwin(1, COLS, LINES - 2, 0);
  g_in     = newwin(1, COLS, LINES - 1, 0);
  wtimeout(stdscr, 30);   /* getch blocks up to 30ms so we can poll the socket */

  {
    char banner[256];
    snprintf(banner, sizeof(banner), "[mipsmon: connected to %s:%s -- Ctrl-\\ or type 'quit' to exit]", g_host, g_port);
    push_line(banner);
  }
  draw();

  bool running = true;
  while(running) {
    if(g_sigint) {                 /* SIGINT slipped through raw() -- forward it, don't die */
      g_sigint = 0;
      send_byte(s, 0x03);
      g_input.clear();
      g_hist_idx = -1;
      g_scroll = 0;
    }
    int ch = wgetch(stdscr);
    if(ch != ERR) {
      if(ch == KEY_PPAGE) {
        g_scroll += (LINES - 2) / 2;
      }
      else if(ch == KEY_NPAGE) {
        g_scroll -= (LINES - 2) / 2;
        if(g_scroll < 0) { g_scroll = 0; }
      }
      else {
        g_scroll = 0;                              /* any other key -> live */
        if(ch == 0x1c) {                           /* Ctrl-\  quit */
          running = false;
        }
        else if(ch == 0x1d) {                      /* Ctrl-]  server monitor toggle */
          send_byte(s, 0x1d);
        }
        else if(ch == 0x12) {                      /* Ctrl-R  LINE/RAW toggle */
          g_raw = !g_raw;
        }
        else if(ch == 0x0c) {                      /* Ctrl-L  redraw */
          clearok(g_out, TRUE);
        }
        else if(ch == 0x03) {                      /* Ctrl-C  pass through to the session */
          send_byte(s, 0x03);                      /* SCC Rx gets the interrupt char... */
          g_input.clear();                         /* ...and, like a shell, drop the LINE-mode edit */
          g_hist_idx = -1;
        }
        else if(g_raw) {
          if(ch == KEY_ENTER || ch == '\n' || ch == '\r') { send_byte(s, '\r'); }
          else if(ch == KEY_BACKSPACE) { send_byte(s, 0x7f); }
          else if(ch >= 0 && ch < 256) { send_byte(s, (char)ch); }
        }
        else {                                     /* LINE-mode editor */
          if(ch == KEY_ENTER || ch == '\n' || ch == '\r') {
            if(g_input == "quit" || g_input == "exit") {
              running = false;                     /* local quit command */
            } else {
              send_str(s, g_input);
              send_byte(s, '\r');
              if(!g_input.empty() && (g_hist.empty() || g_hist.back() != g_input)) {
                g_hist.push_back(g_input);
                while(g_hist.size() > MAX_HISTORY) { g_hist.erase(g_hist.begin()); }
              }
            }
            g_hist_idx = -1;
            g_input.clear();
          }
          else if(ch == KEY_BACKSPACE || ch == 127 || ch == 8) {
            if(!g_input.empty()) { g_input.pop_back(); }
          }
          else if(ch == 0x15) {                    /* Ctrl-U clear line */
            g_input.clear();
          }
          else if(ch == KEY_UP) {
            if(!g_hist.empty()) {
              if(g_hist_idx == -1) { g_saved_input = g_input; g_hist_idx = (int)g_hist.size(); }
              if(g_hist_idx > 0) { g_hist_idx--; g_input = g_hist[g_hist_idx]; }
            }
          }
          else if(ch == KEY_DOWN) {
            if(g_hist_idx != -1) {
              g_hist_idx++;
              if(g_hist_idx >= (int)g_hist.size()) { g_hist_idx = -1; g_input = g_saved_input; }
              else { g_input = g_hist[g_hist_idx]; }
            }
          }
          else if(ch >= 32 && ch < 256) {
            g_input += (char)ch;
          }
        }
      }
    }

    char b[4096];
    int n = (int)read(s, b, sizeof(b));
    if(n > 0) {
      feed_output(b, n);
    }
    else if(n == 0) {
      push_line("[mipsmon: disconnected]");
      draw();
      running = false;
    }

    draw();
  }

  delwin(g_out); delwin(g_status); delwin(g_in);
  endwin();
  printf("[mipsmon quit]\n");
  return 0;
}
