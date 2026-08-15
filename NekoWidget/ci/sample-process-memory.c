// Samples the memory footprint of a Simulator app process on the macOS host.
//
// Usage:
//   sample-process-memory <pid> <csv-path> <stop-file> [interval-ms]
//
// The default interval is 100 ms. Creating stop-file requests a clean exit.
// Exit status 0 means the stop file was observed, 2 means configuration or I/O
// failed, 3 means the target exited or became unavailable, 4 means the PID was
// reused for another process, and 5 means the sampler was interrupted.

#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

enum {
    exit_usage = 2,
    exit_target_unavailable = 3,
    exit_pid_reused = 4,
    exit_interrupted = 5,
};

static volatile sig_atomic_t interruption_requested = 0;

static void handle_signal(int signal_number) {
    (void)signal_number;
    interruption_requested = 1;
}

static bool parse_positive_long(
    const char *value,
    long maximum,
    long *parsed_value
) {
    char *end = NULL;
    errno = 0;
    long parsed = strtol(value, &end, 10);
    if (
        errno != 0
        || end == value
        || *end != '\0'
        || parsed <= 0
        || parsed > maximum
    ) {
        return false;
    }
    *parsed_value = parsed;
    return true;
}

static uint64_t nanoseconds_for_clock(clockid_t clock_identifier) {
    struct timespec value = {0, 0};
    if (clock_gettime(clock_identifier, &value) != 0) {
        return 0;
    }
    return (uint64_t)value.tv_sec * UINT64_C(1000000000)
        + (uint64_t)value.tv_nsec;
}

static int stop_file_exists(const char *path) {
    if (access(path, F_OK) == 0) {
        return 1;
    }
    return errno == ENOENT ? 0 : -1;
}

static bool write_row(
    FILE *output,
    uint64_t sample_index,
    int pid,
    const struct rusage_info_v4 *usage,
    const char *status,
    int error_number
) {
    uint64_t timestamp_epoch_ns = nanoseconds_for_clock(CLOCK_REALTIME);
    uint64_t monotonic_ns = nanoseconds_for_clock(CLOCK_MONOTONIC);
    int result = fprintf(
        output,
        "%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%d,%" PRIu64
        ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%s,%d\n",
        sample_index,
        timestamp_epoch_ns,
        monotonic_ns,
        pid,
        usage == NULL ? 0 : usage->ri_proc_start_abstime,
        usage == NULL ? 0 : usage->ri_proc_exit_abstime,
        usage == NULL ? 0 : usage->ri_resident_size,
        usage == NULL ? 0 : usage->ri_phys_footprint,
        usage == NULL ? 0 : usage->ri_lifetime_max_phys_footprint,
        status,
        error_number
    );
    return result >= 0 && fflush(output) == 0;
}

static void sleep_for_interval(long interval_milliseconds) {
    struct timespec remaining = {
        .tv_sec = interval_milliseconds / 1000,
        .tv_nsec = (interval_milliseconds % 1000) * 1000000L,
    };
    while (
        !interruption_requested
        && nanosleep(&remaining, &remaining) != 0
        && errno == EINTR
    ) {
        // Continue sleeping for the unslept portion of the interval.
    }
}

int main(int argument_count, char *arguments[]) {
    if (argument_count < 4 || argument_count > 5) {
        fprintf(
            stderr,
            "usage: %s <pid> <csv-path> <stop-file> [interval-ms]\n",
            arguments[0]
        );
        return exit_usage;
    }

    long parsed_pid = 0;
    if (!parse_positive_long(arguments[1], INT_MAX, &parsed_pid)) {
        fprintf(stderr, "invalid pid: %s\n", arguments[1]);
        return exit_usage;
    }

    long interval_milliseconds = 100;
    if (
        argument_count == 5
        && !parse_positive_long(arguments[4], 60000, &interval_milliseconds)
    ) {
        fprintf(stderr, "invalid interval in milliseconds: %s\n", arguments[4]);
        return exit_usage;
    }

    FILE *output = fopen(arguments[2], "w");
    if (output == NULL) {
        fprintf(stderr, "cannot open CSV output %s: %s\n", arguments[2], strerror(errno));
        return exit_usage;
    }
    if (
        fprintf(
            output,
            "sample_index,timestamp_epoch_ns,monotonic_ns,pid,"
            "proc_start_abstime,proc_exit_abstime,resident_size_bytes,"
            "phys_footprint_bytes,lifetime_max_phys_footprint_bytes,"
            "status,error_number\n"
        ) < 0
        || fflush(output) != 0
    ) {
        fprintf(stderr, "cannot write CSV header: %s\n", strerror(errno));
        fclose(output);
        return exit_usage;
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    const int target_pid = (int)parsed_pid;
    const char *stop_file = arguments[3];
    uint64_t sample_index = 0;
    uint64_t expected_start_abstime = 0;
    struct rusage_info_v4 last_usage = {0};
    bool has_last_usage = false;
    int exit_status = 0;

    while (true) {
        if (interruption_requested) {
            if (!write_row(
                    output,
                    sample_index,
                    target_pid,
                    has_last_usage ? &last_usage : NULL,
                    "interrupted",
                    EINTR
                )) {
                fprintf(stderr, "cannot write interrupted row: %s\n", strerror(errno));
            }
            exit_status = exit_interrupted;
            break;
        }

        int stop_status = stop_file_exists(stop_file);
        if (stop_status < 0) {
            int saved_errno = errno;
            write_row(
                output,
                sample_index,
                target_pid,
                has_last_usage ? &last_usage : NULL,
                "unavailable",
                saved_errno
            );
            fprintf(stderr, "cannot inspect stop file %s: %s\n", stop_file, strerror(saved_errno));
            exit_status = exit_usage;
            break;
        }
        if (stop_status > 0) {
            if (!write_row(
                    output,
                    sample_index,
                    target_pid,
                    has_last_usage ? &last_usage : NULL,
                    "stop",
                    0
                )) {
                fprintf(stderr, "cannot write stop row: %s\n", strerror(errno));
                exit_status = exit_usage;
            }
            break;
        }

        struct rusage_info_v4 usage = {0};
        if (
            proc_pid_rusage(
                target_pid,
                RUSAGE_INFO_V4,
                (rusage_info_t *)&usage
            ) != 0
        ) {
            int saved_errno = errno;
            write_row(
                output,
                sample_index,
                target_pid,
                has_last_usage ? &last_usage : NULL,
                "unavailable",
                saved_errno
            );
            fprintf(
                stderr,
                "proc_pid_rusage failed for pid %d: %s\n",
                target_pid,
                strerror(saved_errno)
            );
            exit_status = exit_target_unavailable;
            break;
        }

        const char *status = sample_index == 0 ? "start" : "sample";
        if (usage.ri_proc_start_abstime == 0) {
            status = "unavailable";
            exit_status = exit_target_unavailable;
        } else if (expected_start_abstime == 0) {
            expected_start_abstime = usage.ri_proc_start_abstime;
        } else if (usage.ri_proc_start_abstime != expected_start_abstime) {
            status = "pid_reused";
            exit_status = exit_pid_reused;
        }
        if (
            exit_status == 0
            && usage.ri_proc_exit_abstime != 0
        ) {
            status = "exit";
            exit_status = exit_target_unavailable;
        }

        if (!write_row(
                output,
                sample_index,
                target_pid,
                &usage,
                status,
                0
            )) {
            fprintf(stderr, "cannot write memory sample: %s\n", strerror(errno));
            exit_status = exit_usage;
            break;
        }
        last_usage = usage;
        has_last_usage = true;
        sample_index += 1;

        if (exit_status != 0) {
            break;
        }
        sleep_for_interval(interval_milliseconds);
    }

    if (fclose(output) != 0 && exit_status == 0) {
        fprintf(stderr, "cannot close CSV output: %s\n", strerror(errno));
        return exit_usage;
    }
    return exit_status;
}
