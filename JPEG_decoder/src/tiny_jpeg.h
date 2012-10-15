/*
 * tiny_jpeg.h
 *
 *  Created on: Aug 10, 2012
 *      Author: Sudha
 */

void load_jpeg_from_flash();
unsigned short YCbCr_to_RGB565( short, short, short);
unsigned char getByte(unsigned);
unsigned char getDataArray(unsigned, unsigned char []);

enum JpegMarkers {
    // Start of Frame markers, non-differential, Huffman coding
	HuffBaselineDCT = 0xFFC0,

    // Huffman table spec
	HuffmanTableDef = 0xFFC4,

    // Restart Interval termination
    RestartIntervalStart = 0xFFD0,
    RestartIntervalEnd = 0xFFD7,

    // Other markers
    StartOfImage = 0xFFD8,
    EndOfImage = 0xFFD9,
	StartOfScan = 0xFFDA,
	QuantTableDef = 0xFFDB,
	RestartIntervalDef = 0xFFDD,
};

enum {
  Y=0, Cb=1, Cr=2
};

enum ChromaSubsampling {					/* Horizontal and vertical sampling factors in chroma subsampling */
	YUV420 = 0x22,
	YUV422 = 0x21,
	YUV444 = 0x11
};

typedef struct huffEntry {
  unsigned char length;
  unsigned short code;
  unsigned char symbol;
} huffEntry;

static unsigned char dezigzag[64] = {
        0,   1,  8, 16,  9,  2,  3, 10,
        17, 24, 32, 25, 18, 11,  4,  5,
        12, 19, 26, 33, 40, 48, 41, 34,
        27, 20, 13,  6,  7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36,
        29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46,
        53, 60, 61, 54, 47, 55, 62, 63
       };

#define MAX_COMPONENT_COUNT 5

typedef struct stComps{
  unsigned char count;
  unsigned height;
  unsigned width;
  unsigned char ac_table[MAX_COMPONENT_COUNT];
  unsigned char dc_table[MAX_COMPONENT_COUNT];
  unsigned char qt_table[MAX_COMPONENT_COUNT];
  unsigned char sampling_factors[MAX_COMPONENT_COUNT];
  short Y[4][64];
  short Cb[64];
  short Cr[64];
} stComps;
