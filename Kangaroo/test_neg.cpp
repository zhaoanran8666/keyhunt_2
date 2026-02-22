#include <stdio.h>
#include <stdint.h>
#include "SECPK1/Int.h"

int main() {
  Int d;
  d.bits64[0] = 10;
  d.bits64[1] = 0;
  d.bits64[2] = 0;
  d.bits64[3] = 0;
  d.bits64[4] = 0;
  d.ModNegK1order();
  
  printf("%016llX %016llX %016llX %016llX\n", d.bits64[3], d.bits64[2], d.bits64[1], d.bits64[0]);
  return 0;
}
