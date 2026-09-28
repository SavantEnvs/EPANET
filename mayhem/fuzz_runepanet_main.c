/*
 * mayhem/fuzz_runepanet_main.c — Mayhem harness for the `runepanet` target.
 *
 * Thin CLI wrapper around ENepanet(), instead of shipping upstream's
 * run/main.c as-is, so the exit code distinguishes success/warning/failure
 * cleanly for Mayhem. Wall-clock enforcement (a fuzzer-mutated [TIMES]
 * Duration/Hstep can make a single exec run long) is the Mayhemfile's job
 * (`timeout: 30` in mayhem/Mayhemfile_runepanet) — Mayhem owns timeouts, so
 * the harness does not install its own alarm/watchdog.
 */

#include <stdio.h>
#include <stdlib.h>

#include "epanet2.h"

static void writeConsole(char *s)
{
    fprintf(stdout, "\r%s", s);
    fflush(stdout);
}

int main(int argc, char *argv[])
{
    char *f1, *f2, *f3;
    char blank[] = "";
    char errmsg[256] = "";
    int errcode;
    int version;
    int major, minor, patch;

    if (argc < 3)
    {
        printf("\nUsage:\n %s <input_filename> <report_filename> [<binary_filename>]\n",
               argv[0]);
        return 0;
    }

    ENgetversion(&version);
    major = version / 10000;
    minor = (version % 10000) / 100;
    patch = version % 100;
    printf("\n... Running EPANET Version %d.%d.%d\n", major, minor, patch);

    f1 = argv[1];
    f2 = argv[2];
    if (argc > 3) f3 = argv[3];
    else          f3 = blank;

    errcode = ENepanet(f1, f2, f3, &writeConsole);

    printf("\r                                                               ");

    if (errcode == 0)
    {
        printf("\n... EPANET ran successfully.\n");
        return 0;
    }
    else if (errcode < 100)
    {
        printf("\n... EPANET ran with warnings - check the Status Report.\n");
        return 0;
    }
    else
    {
        ENgeterror(errcode, errmsg, 255);
        printf("\n... EPANET failed with %s.\n", errmsg);
        return 100;
    }
}
