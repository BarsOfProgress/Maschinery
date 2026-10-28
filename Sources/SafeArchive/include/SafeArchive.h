#pragma once
#include <stdint.h>
#include <stddef.h>
int mm_extract_archive(const char *source, const char *destination, int64_t maximum_bytes, int (*cancelled)(void), char *error, size_t error_size);
