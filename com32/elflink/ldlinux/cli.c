#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <console.h>
#include <com32.h>
#include <syslinux/adv.h>
#include <syslinux/config.h>
#include <setjmp.h>
#include <netinet/in.h>
#include <limits.h>
#include <minmax.h>
#include <linux/list.h>
#include <sys/exec.h>
#include <sys/module.h>
#include <dprintf.h>
#include <core.h>

#include "getkey.h"
#include "menu.h"
#include "cli.h"
#include "config.h"

static struct list_head cli_history_head;

void clear_screen(void)
{
    //dprintf("enter");
    fputs("\033e\033%@\033)0\033(B\1#0\033[?25l\033[2J", stdout);
}

static int mygetkey_timeout(clock_t *kbd_to, clock_t *tto)
{
    clock_t t0, t1;
    int key;

    t0 = times(NULL);
    key = get_key(stdin, *kbd_to ? *kbd_to : *tto);

    /* kbdtimeout only applies to the first character */
    if (*kbd_to)
	*kbd_to = 0;

    t1 = times(NULL) - t0;
    if (*tto) {
	/* Timed out. */
	if (*tto <= (long long)t1)
	    key = KEY_NONE;
	else {
	    /* Did it wrap? */
	    if (*tto > totaltimeout)
		key = KEY_NONE;

	    *tto -= t1;
	}
    }

    return key;
}

static const char * cmd_reverse_search(int *cursor, clock_t *kbd_to,
				       clock_t *tto)
{
    int key;
    int i = 0;
    char buf[MAX_CMDLINE_LEN];
    const char *p = NULL;
    struct cli_command *last_found;
    struct cli_command *last_good = NULL;

    last_found = list_entry(cli_history_head.next, typeof(*last_found), list);

    memset(buf, 0, MAX_CMDLINE_LEN);

    printf("\033[1G\033[1;36m(reverse-i-search)`': \033[0m");
    while (1) {
	key = mygetkey_timeout(kbd_to, tto);

	if (key == KEY_CTRL('C')) {
	    return NULL;
	} else if (key == KEY_CTRL('R')) {
	    if (i == 0)
		continue; /* User typed nothing yet */
	    /* User typed 'CTRL-R' again, so try the next */
	    last_found = list_entry(last_found->list.next, typeof(*last_found), list);
	} else if (key >= ' ' && key <= 'z') {
	        buf[i++] = key;
	} else {
	    /* Treat other input chars as terminal */
	    break;
	}

	while (last_found) {
	    p = strstr(last_found->command, buf);
	    if (p)
	        break;

	    if (list_is_last(&last_found->list, &cli_history_head))
		break;

	    last_found = list_entry(last_found->list.next, typeof(*last_found), list);
	}

	if (!p && !last_good) {
	    return NULL;
	} else if (!p) {
	    continue;
	} else {
	    last_good = last_found;
            *cursor = p - last_good->command;
	}

	printf("\033[?7l\033[?25l");
	/* Didn't handle the line wrap case here */
	printf("\033[1G\033[1;36m(reverse-i-search)\033[0m`%s': %s",
		buf, last_good->command ? : "");
	printf("\033[K\r");
    }

    return last_good ? last_good->command : NULL;
}



const char *edit_cmdline(const char *input, int top /*, int width */ ,
			 int (*pDraw_Menu) (int, int, int),
			 int (*show_fkey) (int), bool *timedout)
{
    static char cmdline[MAX_CMDLINE_LEN] = { };
    int cursor_dy=-1;
    int cursor_dx =-1;

    int key, len, cmdline_ptr;
    int redraw = 0;

    bool done = false;
    const char *ret;
    int width = 0;
    struct cli_command *comm_counter = NULL;
    clock_t kbd_to = kbdtimeout;
    clock_t tto = totaltimeout;

    if (!width) {
	int height;
	if (getscreensize(1, &height, &width))
	    width = 80;
    }

    len = cmdline_ptr = 0;

    printf("\0337"); 			//save cursor with scroll
    printf("%s ", input);

    while (!done) {
	if (redraw > 1) {
	    /* Clear and redraw whole screen */
	    /* Enable ASCII on G0 and DEC VT on G1; do it in this order
	       to avoid confusing the Linux console */
	    clear_screen();
	    if (pDraw_Menu)
		    (*pDraw_Menu) (-1, top, 1);
	    printf("\033[2J\033[H");			//clear entire screen, move cursor to upper left corner
	    printf("\0337"); 				//save cursor with scroll
	}

    if (redraw > 0) {

        /* Redraw the command line */
        printf("\033[?25l");	//hides the cursor
        printf("\0338"); 	//recover cursor with scroll
        printf("%s ", input); 	//input = "boot:"

        printf("%s", cmdline);

        printf("\033[K\r");	//clear line from cursor right

        printf("\0338"); 	//recover cursor with scroll


        cursor_dy = ((strlen(input) +1 + cmdline_ptr ) / width );
        if(cursor_dy !=0 )
            printf("\033[%dB",cursor_dy);	//Move cursor down N lines

        cursor_dx  = ((strlen(input) +1 + cmdline_ptr +1 ) % width );
        if(cursor_dx==0)
            cursor_dx=width;

        printf("\033[%dC", cursor_dx-1);	//move cursor right N columns from current position
        printf("\033[?25h");			//shows the cursor

        redraw = 0;
    }

    key = mygetkey_timeout(&kbd_to, &tto);

    switch (key) {
    case KEY_NONE:
        /* We timed out. */
        *timedout = true;
        return NULL;

    case KEY_CTRL('L'):
        redraw = 2;
        break;

    case KEY_ENTER:
    case KEY_CTRL('J'):
        ret = cmdline;
        done = true;
        break;

    case KEY_BACKSPACE:
    case KEY_DEL:
        if (cmdline_ptr) {
            memmove(cmdline + (cmdline_ptr - 1), cmdline + cmdline_ptr,
                strlen(cmdline + cmdline_ptr)+1);

            len--;
            cmdline_ptr--;
            redraw = 1;
        }
        break;

    case KEY_CTRL('D'):
    case KEY_DELETE:
        if (cmdline_ptr < len) {
            memmove(cmdline + cmdline_ptr, cmdline + cmdline_ptr + 1, len - cmdline_ptr);
            len--;
            redraw = 1;
        }
        break;

    case KEY_CTRL('U'):
        if (len) {
            len = cmdline_ptr = 0;
            cmdline[len] = '\0';
            redraw = 1;
            printf("\0338"); 		//Recover cursor with scroll
            printf("\033[0J");		//Clear screen from cursor down
        }
        break;

    case KEY_CTRL('W'):
        if (cmdline_ptr) {
            int prevcursor = cmdline_ptr;

            while (cmdline_ptr && my_isspace(cmdline[cmdline_ptr - 1]))
                cmdline_ptr--;

            while (cmdline_ptr && !my_isspace(cmdline[cmdline_ptr - 1]))
                cmdline_ptr--;

#if 0
            memmove(cmdline + cmdline_ptr, cmdline + prevcursor,
                len - prevcursor + 1);
#else
            {
                int i;
                char *q = cmdline + cmdline_ptr;
                char *p = cmdline + prevcursor;
                for (i = 0; i < len - prevcursor + 1; i++)
                *q++ = *p++;
            }
#endif
            len -= (prevcursor - cmdline_ptr);
            redraw = 1;
            printf("\0338"); 		//Recover cursor with scroll
            printf("\033[0J");		//Clear screen from cursor down
        }
        break;

    case KEY_LEFT:
    case KEY_CTRL('B'):
        if (cmdline_ptr) {
            cmdline_ptr--;
            redraw = 1;
        }
        break;

    case KEY_RIGHT:
    case KEY_CTRL('F'):
        if (cmdline_ptr < len) {
            putchar(cmdline[cmdline_ptr]);
            cmdline_ptr++;
        }
        break;

    case KEY_CTRL('K'):
        if (cmdline_ptr < len) {
            cmdline[len = cmdline_ptr] = '\0';
            redraw = 1;
            printf("\033[0J");		//Clear screen from cursor down
        }
        break;

    case KEY_HOME:
    case KEY_CTRL('A'):
        if (cmdline_ptr) {
            cmdline_ptr = 0;
            redraw = 1;
        }
        break;

    case KEY_END:
    case KEY_CTRL('E'):
        if (cmdline_ptr != len) {
            cmdline_ptr = len;
            redraw = 1;
        }
        break;

    case KEY_F1:
    case KEY_F2:
    case KEY_F3:
    case KEY_F4:
    case KEY_F5:
    case KEY_F6:
    case KEY_F7:
    case KEY_F8:
    case KEY_F9:
    case KEY_F10:
    case KEY_F11:
    case KEY_F12:
        if (show_fkey != NULL) {
            if((*show_fkey) (key)==0)
                printf("\0337"); 		//save cursor with scroll
            redraw = 1;
        }
        break;
    case KEY_CTRL('P'):
    case KEY_UP:
        {
            if (!list_empty(&cli_history_head)) {
                struct list_head *next;

                if (!comm_counter)
                    next = cli_history_head.next;
                else
                    next = comm_counter->list.next;

                comm_counter =
                    list_entry(next, typeof(*comm_counter), list);

                if (&comm_counter->list != &cli_history_head)
                    strcpy(cmdline, comm_counter->command);

                cmdline_ptr = len = strlen(cmdline);
                redraw = 1;
                printf("\0338"); 		//Recover cursor with scroll
                printf("\033[0J");		//Clear screen from cursor down
            }
        }
        break;
    case KEY_CTRL('N'):
    case KEY_DOWN:
        {
            if (!list_empty(&cli_history_head)) {
                struct list_head *prev;

                if (!comm_counter)
                    prev = cli_history_head.prev;
                else
                    prev = comm_counter->list.prev;

                comm_counter =
                    list_entry(prev, typeof(*comm_counter), list);

                if (&comm_counter->list != &cli_history_head)
                    strcpy(cmdline, comm_counter->command);

                cmdline_ptr = len = strlen(cmdline);
                redraw = 1;
                printf("\0338"); 		//Recover cursor wih scroll
                printf("\033[0J");		//Clear screen from cursor down
            }
        }
        break;
    case KEY_CTRL('R'):
        {
             /*
              * Handle this case in another function, since it's
              * a kind of special.
              */
            const char *p = cmd_reverse_search(&cmdline_ptr, &kbd_to, &tto);
            if (p) {
                strcpy(cmdline, p);
                len = strlen(cmdline);
            } else {
                cmdline[0] = '\0';
                cmdline_ptr = len = 0;
            }
            redraw = 1;
        }
        break;
    case KEY_TAB:
        {
            const char *p;
            size_t len;

            /* Label completion enabled? */
            if (nocomplete)
                break;

            p = cmdline;
            len = 0;
            while(*p && !my_isspace(*p)) {
                p++;
                len++;
            }

            if(print_labels(cmdline, len))
                printf("\0337"); 		//save cursor with scroll
            redraw = 1;
            break;
        }
    case KEY_CTRL('V'):
        if (BIOSName)
            printf("%s%s%s", syslinux_banner,
                (char *)MK_PTR(0, BIOSName), copyright_str);
        else
            printf("%s%s", syslinux_banner, copyright_str);

        printf("\0337"); 		//save cursor with scroll
        redraw = 1;
        break;

    default:
        if (key >= ' ' && key <= 0xFF && len < MAX_CMDLINE_LEN - 1)
        {
            if (cmdline_ptr == len)
            {
                cmdline[len++] = key;
                cmdline[len] = '\0';
                putchar(key);
                cmdline_ptr++;
            }
            else
            {
                if (cmdline_ptr > len)
                    return NULL;

                memmove(cmdline + cmdline_ptr + 1, cmdline + cmdline_ptr,
                    len - cmdline_ptr + 1);
                cmdline[cmdline_ptr++] = key;
                len++;
                redraw = 1;
            }
        }
        break;
    }
    }

    printf("\033[?7h");

    /* Add the command to the history if its length is larger than 0 */
    len = strlen(ret);
    if (len > 0) {
        comm_counter = malloc(sizeof(struct cli_command));
        comm_counter->command = malloc(sizeof(char) * (len + 1));
        strcpy(comm_counter->command, ret);
        list_add(&(comm_counter->list), &cli_history_head);
    }

    return len ? ret : NULL;
}

static int __constructor cli_init(void)
{
	INIT_LIST_HEAD(&cli_history_head);

	return 0;
}

static void __destructor cli_exit(void)
{
	/* Nothing to do */
}
