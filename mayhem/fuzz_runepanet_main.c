/*
 * mayhem/fuzz_runepanet_main.c — Mayhem harness for the `runepanet` target.
 *
 * WHY THIS EXISTS (instead of shipping upstream's run/main.c as-is):
 *
 * EPANET's hydraulic/quality simulation loops walk from t=0 to t=Duration in
 * steps of Hstep (both read straight from the .inp [TIMES] section, with no
 * upper bound anywhere in src/hydraul.c or src/quality.c). Real-world .inp
 * files keep Duration in the tens-of-hours range, so this is a non-issue in
 * practice — but it is trivial for a fuzzer to mutate a numeric duration
 * field ("Duration <big number>") and produce a syntactically valid network
 * whose simulation would legitimately run for the fuzzer-chosen number of
 * simulated hours, with EPANET faithfully doing that work one step at a time.
 *
 * Confirmed locally: mutating just net1.inp's Duration from 24:00 to
 * 999999:00 makes runepanet still be inside `ENepanet()` after 10 real
 * seconds, having only processed ~1/4 of the requested simulated duration —
 * i.e. no crash, no infinite loop, just unbounded proportional CPU cost
 * driven directly by attacker-controlled input. Under Mayhem's cmd-mode
 * (fork+exec per test case), this makes nearly every mutated input run right
 * up against the per-exec timeout, which is exactly the observed pathology
 * across real runs #4/#5/#6: ~18-54 total executions at ~0.5-1.2 execs/sec
 * and has_critical_errors=True from the run supervisor, with n_defects=0
 * (this is not a crash bug — it's a throughput-killing hang).
 *
 * FIX: bound wall-clock time per execution from the harness side, well
 * under Mayhem's own per-exec timeout, so a pathological Duration/Hstep
 * combination gets cut short deterministically instead of eating the whole
 * exec budget. This is a harness-level guard (like libFuzzer's own
 * -timeout=N for in-process targets) — it does not change EPANET's solver
 * behavior or any upstream source file.
 */

#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>

#include "epanet2.h"

/* Generous per-exec wall-clock cap: real seed networks (net1/example_1/
 * Net2, 24-55 simulated hours) finish in well under 100ms. A few seconds is
 * ample headroom for legitimate mutations while keeping throughput high. */
#define RUNEPANET_WALLCLOCK_CAP_SECS 5

static void writeConsole(char *s)
{
    fprintf(stdout, "\r%s", s);
    fflush(stdout);
}

static void onAlarm(int sig)
{
    (void)sig;
    /* Async-signal-safe write instead of fprintf/exit. Exit code is
     * distinct from EPANET's own 0/1-99/100 range so this is identifiable
     * as a harness-imposed cutoff rather than a real EPANET result. */
    static const char msg[] =
        "\n... runepanet: wall-clock cap hit, aborting execution.\n";
    write(STDERR_FILENO, msg, sizeof(msg) - 1);
    _exit(124);
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

    signal(SIGALRM, onAlarm);
    alarm(RUNEPANET_WALLCLOCK_CAP_SECS);

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

    alarm(0);

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
