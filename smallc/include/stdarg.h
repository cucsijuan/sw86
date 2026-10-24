/* stdarg.h - functions with a variable number of arguments
 *
 * Arguments are words on the stack, the first one lowest: va_arg takes
 * them one after the other from the last named parameter on.
 */
#ifndef _STDARG_H
#define _STDARG_H

#define va_list             char *
#define va_start(ap, last)  ((ap) = (char *)&(last) + 2)
#define va_arg(ap, type)    (*(type *)(((ap) = (ap) + 2) - 2))
#define va_end(ap)

#endif
