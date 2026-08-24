#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <utf8proc.h>

static int read_stdin(uint8_t **buffer, size_t *length) {
    size_t capacity = 4096;
    uint8_t *data = malloc(capacity);

    if (data == NULL) {
        return -1;
    }

    *length = 0;
    while (!feof(stdin)) {
        size_t available;
        size_t received;

        if (*length == capacity) {
            uint8_t *grown;

            if (capacity > SIZE_MAX / 2) {
                free(data);
                errno = ENOMEM;
                return -1;
            }
            capacity *= 2;
            grown = realloc(data, capacity);
            if (grown == NULL) {
                free(data);
                return -1;
            }
            data = grown;
        }

        available = capacity - *length;
        received = fread(data + *length, 1, available, stdin);
        *length += received;
        if (received == 0 && ferror(stdin)) {
            free(data);
            return -1;
        }
    }

    *buffer = data;
    return 0;
}

int main(int argc, char **argv) {
    uint8_t *input = NULL;
    uint8_t *normalized = NULL;
    uint8_t *folded = NULL;
    size_t input_length = 0;
    utf8proc_ssize_t normalized_length;
    utf8proc_ssize_t folded_length;

    if (argc != 1) {
        fprintf(stderr, "usage: %s < UTF-8\n", argv[0]);
        return 2;
    }
    if (read_stdin(&input, &input_length) != 0) {
        fprintf(stderr, "unable to read UTF-8 input: %s\n", strerror(errno));
        return 1;
    }
    if (input_length > (size_t)PTRDIFF_MAX) {
        fprintf(stderr, "UTF-8 input is too large\n");
        free(input);
        return 1;
    }

    /* Keep these as two passes. Python's reference behavior is NFKC(s).casefold(),
     * which is observably different from the composed NFKC_Casefold form. */
    normalized_length = utf8proc_map(
        input, (utf8proc_ssize_t)input_length, &normalized,
        UTF8PROC_COMPAT | UTF8PROC_COMPOSE
    );
    free(input);
    if (normalized_length < 0) {
        fprintf(stderr, "invalid UTF-8 input: %s\n", utf8proc_errmsg(normalized_length));
        return 1;
    }

    folded_length = utf8proc_map(
        normalized, normalized_length, &folded, UTF8PROC_CASEFOLD
    );
    free(normalized);
    if (folded_length < 0) {
        fprintf(stderr, "unable to case-fold UTF-8 input: %s\n", utf8proc_errmsg(folded_length));
        return 1;
    }

    if (folded_length > 0 &&
        fwrite(folded, 1, (size_t)folded_length, stdout) != (size_t)folded_length) {
        fprintf(stderr, "unable to write normalized UTF-8 output: %s\n", strerror(errno));
        free(folded);
        return 1;
    }
    free(folded);
    return 0;
}
