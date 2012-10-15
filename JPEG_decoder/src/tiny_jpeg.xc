#include <flashlib.h>
#include <platform.h>
#include <stdio.h>
#include <stdlib.h>
#include "tiny_jpeg.h"

inline unsigned char getByte(unsigned);
inline unsigned short YCbCr_to_RGB565( short, short, short);
int Decode();
extern void init_idct (void);
extern void idct(short a[]);

#define HUF_TBL_SIZE 256
unsigned  jpg_start_addr=65536-65536;	// corresponds to sector number 16 in flash but sector 0 in data partition if 65536 is set as the starting address of data partition.
unsigned rgb_start_addr=81920-65536;	// corresponds to sector number 20 in flash but sector 4 in data partition
#define IMAGE_SIZE 3814	// JPG image size

unsigned char image[IMAGE_SIZE];

// PORT DECLARATION
fl_SPIPorts flash_ports = { PORT_SPI_MISO,
							PORT_SPI_SS,
							PORT_SPI_CLK,
							PORT_SPI_MOSI,
							XS1_CLKBLK_1 };


// Array of allowed flash devices from "SpecMacros.h"
fl_DeviceSpec myFlashDevices[] = {	FL_DEVICE_ATMEL_AT25FS010,
									FL_DEVICE_ATMEL_AT25DF041A,
									FL_DEVICE_WINBOND_W25X10,
									FL_DEVICE_WINBOND_W25X20 };


/*
 * getByte returns a byte from the jpeg. It must be used sequentially, i.e.
 * offset must increase with each call.
 */
#pragma unsafe arrays
inline unsigned char getByte(unsigned offset){
  	return image[offset];
}

//does the same as above but with a short
#pragma unsafe arrays
unsigned short getShort(unsigned offset){
  	unsigned char dataH,dataL; //Image data
  	unsigned short data;

  	// READ two bytes of JPG IMAGE data from memory
  	dataH = image[offset]; dataL = image[offset+1];

  	data = dataH<<8 | dataL;
    return data;
}

/* Fetches one page from flash */
#pragma unsafe arrays
inline unsigned char getDataArray(unsigned offset, unsigned char buf[]){
	for (int i=0;i<65;i++) buf[i]=image[offset+i];
    return buf[0];
}

// unpack the DQT into a table
#pragma unsafe arrays
static inline unsigned DecodeDQT(unsigned offset, unsigned char qtab[4][64]) {
  unsigned char buf [65];
  unsigned length = getShort(offset);
  offset += 2;
  while (length >= 65) {
	unsigned char i = getDataArray(offset,buf);
    for (unsigned index = 0; index < 64; ++index) {
    	qtab[i][index] = buf[index+1];
    }
    offset += 65;
    length -= 65;
  }
  return offset;
}

//read the image definition stuff and save it in the components structure
#pragma unsafe arrays
static inline unsigned DecodeHuffBaselineDCT( unsigned offset, stComps &components) {
  unsigned length = getShort(offset);
  unsigned height = getShort(offset + 3);
  unsigned width = getShort(offset + 5);
  unsigned num_components = getByte(offset + 7);

  components.height = height;
  components.width = width;

  for(unsigned i = offset + 8; i< offset + 8 + 3*num_components; i+=3){
    unsigned id =  getByte(i);
    components.sampling_factors[id-1] = getByte(i+1);
    components.qt_table[id-1] = getByte(i+2);
  }
  return offset + length;
}


//read the huffman tables out of their compressed form into a table
#pragma unsafe arrays
static inline unsigned DecodeHuffmanTableDef(unsigned offset, unsigned huffTableSize[4],
    huffEntry huffTable[4][HUF_TBL_SIZE]) {

  unsigned length = getShort(offset);
  unsigned endOfSection = offset + length;
  offset += 2;
  while (offset < endOfSection) {
    //the total number of codes must be less than 256
    int hufcounter = 0;
    int codelengthcounter = 1;
    unsigned tblID = getByte(offset);
    unsigned ht_number = tblID&0xf;
    unsigned ac_dc = (tblID>>4)&0x1;
    unsigned tblIndex = ac_dc | (ht_number<<1);
    unsigned symbol_index = 16;
    unsigned entry = 0;
    offset += 1;
    huffTableSize[tblIndex] = length - symbol_index;

    for (unsigned i = 0; i < 16; i++) {
      unsigned length = i + 1;
      unsigned count = getByte(offset + i);
      for (unsigned j = 0; j < count; j++) {
        unsigned symbol = getByte(offset + symbol_index);
        while (1) {
          if (length == codelengthcounter) {
            huffTable[tblIndex][entry].length = length;
            huffTable[tblIndex][entry].code = hufcounter;
            huffTable[tblIndex][entry].symbol = symbol;
            entry++;
            hufcounter++;
            break;
          } else {
            hufcounter = (hufcounter << 1 );
            codelengthcounter++;
          }
        }
        symbol_index++;
      }
    }

    offset += symbol_index;
  }
  return endOfSection;
}

unsigned g_streamOffset;
unsigned g_bitOffset;
unsigned g_stream_buffer;

//set up the stream interface
void initStream(unsigned offset) {
  unsigned char t;
  g_streamOffset = offset;
  g_bitOffset = 0;

  t = getByte(g_streamOffset);
  g_stream_buffer = t<<24;
  g_streamOffset = g_streamOffset + 1 + (t == 0xff);

  t = getByte(g_streamOffset);
  g_stream_buffer |= t<<16;
  g_streamOffset = g_streamOffset + 1 + (t == 0xff);

  t = getByte(g_streamOffset);
  g_stream_buffer |= t<<8;
  g_streamOffset = g_streamOffset + 1 + (t == 0xff);

  t = getByte(g_streamOffset);
  g_stream_buffer |= t;
  g_streamOffset = g_streamOffset + 1 + (t == 0xff);
}

//get the latest 16 bits from the head of the stream
static inline unsigned short getStream() {
  return (unsigned short)(g_stream_buffer>>(16-g_bitOffset));
}

static inline void advanceStream(char bits_matched) {
  unsigned short t;
  g_bitOffset += bits_matched;
  if(g_bitOffset<16) return;
  while (g_bitOffset > 8) {
    g_bitOffset -= 8;
    g_stream_buffer <<= 8;
    t = getByte(g_streamOffset);
    g_stream_buffer |= t;
    g_streamOffset = g_streamOffset + 1 + (t == 0xff);
  }
}

//find the symbol in the huffman table that matches n of the latest 16 bits
#pragma unsafe arrays
static inline unsigned char matchCode(unsigned short next16bits, const huffEntry huffTable[HUF_TBL_SIZE], char &symbol) {
  unsigned i = 0;
  while (i < HUF_TBL_SIZE) {
    unsigned short mask = next16bits >> (16 - huffTable[i].length);
    if (mask == huffTable[i].code) {
      symbol = huffTable[i].symbol;
      return huffTable[i].length;
    }
    i++;
  }
  return 0;
}

// decodes a channel into a idct'ed matrix
#pragma unsafe arrays
static void DecodeChannel(short channel[64],
    const huffEntry huffTable[4][HUF_TBL_SIZE], unsigned dc_table, unsigned ac_table, short &prevDC,
    const unsigned char qt[64]) {
  unsigned char symbol;
  unsigned i;
  unsigned short next16bits = getStream();
  unsigned num_matched;

  i = 0;

  num_matched = matchCode(next16bits, huffTable[dc_table], symbol);

  advanceStream(num_matched);
  next16bits = getStream();

  for(unsigned j=0;j<64;j++){
    channel[j] = 0;
  }

  if (symbol != 0) {
    unsigned topbits = (symbol >> 4);
    unsigned bottombits = symbol & 0xf;
    short additional = next16bits >> (16 - bottombits);
    short dc;
    if (additional >> (bottombits - 1)) {
      dc = additional;
    } else {
      dc = additional - (1 << (bottombits)) + 1;
    }
    advanceStream(bottombits);
    next16bits = getStream();
    topbits+=i;
    for(;i<topbits;i++){
      channel[dezigzag[i]] = 0;
    }
    channel[dezigzag[i]] = (dc + prevDC) * qt[i];
    prevDC = dc+ prevDC;
  } else {
    channel[dezigzag[i]] = (0 + prevDC)* qt[i];
    prevDC = 0+ prevDC;
  }

  i++;
  num_matched = matchCode(next16bits, huffTable[ac_table], symbol);


  while (symbol) {
    advanceStream(num_matched);
    next16bits = getStream();
    {
    unsigned topbits = (symbol >> 4)&0xf;
    unsigned bottombits = symbol & 0xf;
    short additional = next16bits >> (16 - bottombits);
    short dc;
    if (additional >> (bottombits - 1)) {
      dc = additional;
    } else {
      dc = additional - (1 << (bottombits)) + 1;
    }
    advanceStream(bottombits);
    next16bits = getStream();
    i+=topbits;
    channel[dezigzag[i]] = dc * qt[i];
    }
    i++;
    num_matched = matchCode(next16bits, huffTable[ac_table], symbol);
  }

  advanceStream(num_matched);
}




//colour space conversion
inline unsigned short YCbCr_to_RGB565( short Y, short Cb, short Cr )
{
  unsigned short r,g,b;

  r = Y+1402*(Cr-128)/1000;
  g = Y-34414*(Cb-128)/100000-71414*(Cr-128)/100000;
  b = Y+1772*(Cb-128)/1000;

  r = (r>>3);
  g = (g>>2);
  b = (b>>3);

  return r|(g<<5)|(b<<11);
}

//read the data out of the stream mcu by mcu
#pragma unsafe arrays
int DecodeScan(unsigned offset,short res_int_mcus,
    const unsigned huffTableSize[4], const huffEntry huffTable[4][HUF_TBL_SIZE],
    const unsigned char qt[4][64], stComps &components) {

  short restart_marker, prevDC = 0, prevDCCr = 0, prevDCCb = 0;
  unsigned mcu=0, mcu_count;	// mcu is minimum coded unit.
  unsigned col = 0, row = 0;
  short RGB[2][64*4];	// First dimension: double buffer; one for odd MCU and the other for even.
  	  	  	  	  	  	// Second dimension: 64*4 used for 4:2:0; 64*2 used for 4:2:2; 64 used for 4:4:4.

  if (components.sampling_factors[0]==YUV420)  // 4:2:0 chroma subsampling
	  mcu_count = ((components.height+15)/16) * ((components.width+15)/ 16);
  else if (components.sampling_factors[0]==YUV422)	// 4:2:2 chroma subsampling
	  mcu_count = ((components.height+7)/8) * ((components.width+15)/16);
  else if (components.sampling_factors[0]==YUV444)	// 4:4:4 chroma subsampling
	  mcu_count = ((components.height+7)/8) * ((components.width+7)/8);

  init_idct();
  initStream(offset);

  while (mcu < mcu_count) {

	unsigned ac_table_index = components.ac_table[Y];
    unsigned dc_table_index = components.dc_table[Y];
    unsigned qt_index = components.qt_table[Y];
    	DecodeChannel(components.Y[0], huffTable, dc_table_index, ac_table_index, prevDC, qt[qt_index]);
    if (components.sampling_factors[0]==YUV422 || components.sampling_factors[0]==YUV420)
    	DecodeChannel(components.Y[1], huffTable, dc_table_index, ac_table_index, prevDC, qt[qt_index]);
    if (components.sampling_factors[0]==YUV420){
    	DecodeChannel(components.Y[2], huffTable, dc_table_index, ac_table_index, prevDC, qt[qt_index]);
    	DecodeChannel(components.Y[3], huffTable, dc_table_index, ac_table_index, prevDC, qt[qt_index]);
    }


    ac_table_index = components.ac_table[Cb];
    dc_table_index = components.dc_table[Cb];
    qt_index = components.qt_table[Cb];
    DecodeChannel(components.Cb, huffTable, dc_table_index, ac_table_index, prevDCCb, qt[qt_index]);


    ac_table_index = components.ac_table[Cr];
    dc_table_index = components.dc_table[Cr];
    qt_index = components.qt_table[Cr];
    DecodeChannel(components.Cr, huffTable, dc_table_index, ac_table_index, prevDCCr, qt[qt_index]);


    	idct(components.Y[0]);
    if (components.sampling_factors[0]==YUV422 || components.sampling_factors[0]==YUV420)
    	idct(components.Y[1]);
    if (components.sampling_factors[0]==YUV420){
    	idct(components.Y[2]);
    	idct(components.Y[3]);
    }
    	idct(components.Cb);
    	idct(components.Cr);


    //now reconstruct the rgb
    for (unsigned i = 0; i < 64; i++) {

    	short y,Y0,Y1,Y2,Y3,Cb,Cr;
    	unsigned yy, r;

    	if (components.sampling_factors[0]==YUV420){  // 4:2:0 chroma subsampling
    		y = (1&(i>>2)) + 2*(i>=32);
    	    yy = 2*(i-(i&4)) &0x3f;
    	    r = 4*i-(2*(i&0x7));
    	}
    	else if (components.sampling_factors[0]==YUV422){	// 4:2:2 chroma subsampling
    		y = 1&(i>>2);
    		yy = (i&0xf8)+(i&3)*2;
    		r = i*2;
    	}
    	else if (components.sampling_factors[0]==YUV444){	// 4:4:4 chroma subsampling
    		y=0;
    		yy = i;
    		r = i;
    	}

    	  Y0 = (components.Y[y][yy] - 128) & 0xff;
      if (components.sampling_factors[0]==YUV422 || components.sampling_factors[0]==YUV420)
    	  Y1 = (components.Y[y][yy+1] - 128) & 0xff;
      if (components.sampling_factors[0]==YUV420){
    	  Y2 = (components.Y[y][yy+8] - 128) & 0xff;
    	  Y3 = (components.Y[y][yy+9] - 128) & 0xff;
      }

      Cb = (components.Cb[i] - 128) & 0xff;
      Cr = (components.Cr[i] - 128) & 0xff;

      	  // Every 2x2 block of image pixels is assigned different Y but same Cb and Cr in 4:2:0.
      	  // Every two horizontal pixels are assigned the same Cb and Cr in 4:2:2.
      	  // Each pixel is assigned with its own Y,Cb and Cr in 4:4:4.
      	  RGB[mcu&1][r] = YCbCr_to_RGB565(Y0, Cb, Cr);
      if (components.sampling_factors[0]==YUV422 || components.sampling_factors[0]==YUV420)
      	  RGB[mcu&1][r+1] = YCbCr_to_RGB565(Y1, Cb, Cr);
      if (components.sampling_factors[0]==YUV420){
      	  RGB[mcu&1][r+16] = YCbCr_to_RGB565(Y2, Cb, Cr);
      	  RGB[mcu&1][r+17] = YCbCr_to_RGB565(Y3, Cb, Cr);
      }
    }	// for

    mcu++;

	// Restart marker check
    if (res_int_mcus) if (mcu%res_int_mcus==0){
	  restart_marker = getShort(offset);
	  if (restart_marker<RestartIntervalStart && restart_marker>RestartIntervalEnd){
		  return -1;
	  }
	  offset+=2;
	  prevDC = 0; prevDCCr = 0; prevDCCb = 0;
    }

	if (components.sampling_factors[0]==YUV420){  // 4:2:0 chroma subsampling
	    col += 16;
	    if(col >= components.width){
	      col = 0;
	      row += 16;
	    }
  	}
	else if (components.sampling_factors[0]==YUV422){		// 4:2:2 chroma subsampling
	    col += 16;
	    if(col >= components.width){
	      col = 0;
	      row += 8;
	    }
	}
	else if (components.sampling_factors[0]==YUV444){	// 4:4:4 chroma subsampling
	    col += 8;
	    if(col >= components.width){
	      col = 0;
	      row += 8;
	    }
	}
  }	// while
  return 0;
}


//top level decode function
int Decode() {
  unsigned huffTableSize[4];
  huffEntry huffTable[4][HUF_TBL_SIZE];
  unsigned char qt[4][64];
  stComps components;
  unsigned offset = 2;
  short res_int_MCUs;

  if (getShort(0) != StartOfImage) return -1;

  while (getShort(offset) !=  EndOfImage) {	// loop until end of image

    unsigned short marker = getShort(offset);
    offset += 2;

    switch (marker) {
    case QuantTableDef: {
      offset = DecodeDQT(offset, qt);
      break;
    }
    case HuffBaselineDCT: {
      offset = DecodeHuffBaselineDCT(offset, components);
      break;
    }
    case HuffmanTableDef: {
      offset = DecodeHuffmanTableDef(offset, huffTableSize, huffTable);
      break;
    }
    case RestartIntervalDef: {
    	res_int_MCUs = getShort(offset);
    	offset+=2;
       break;
    }
    case StartOfScan: {
      unsigned length =getShort(offset);
      unsigned num_components = getByte(offset+2);
      components.count = num_components;
      for(unsigned i=0;i<num_components;i++){
        unsigned char component_id = getByte(offset+3+2*i);
        unsigned tblInfo = getByte(offset+3+2*i+1);
        unsigned char ac_table = tblInfo&0xf;
        unsigned char dc_table = tblInfo>>4;
        components.ac_table[component_id-1] = 1 | (ac_table<<1) ;
        components.dc_table[component_id-1] = 0 | (dc_table<<1) ;
      }
      offset += length;
      DecodeScan(offset, res_int_MCUs, huffTableSize, huffTable, qt, components);
      return 0;
    }
    default: {
      unsigned length = getShort(offset);
      offset += length;
      break;
    }
    }	// switch
  }	// while
  return 0;
}

int flash_image_to_memory(){
	unsigned  image_size=IMAGE_SIZE;
	if (0!=fl_readData(jpg_start_addr,image_size,image)) return -1;
}

int main(){

	timer t;	//Timer for finding computation time.
	long int t1,t2,t0;

	/* Connect to the FLASH */
	if (0!=fl_connectToDevice(flash_ports, myFlashDevices, 4)) return -1;

	/* Move image from flash to memory */
	flash_image_to_memory();

	t:>t1;	//Start clock cycle

	par{
			{
				t:>t1;	//Start clock cycle
				Decode();
				t:>t2;	//End clock cycle
			  t0=t2-t1;
			  printf("\n Number of clock cycles consumed (100 MHz clock): %d,%d,%u\n",t1,t2,t0);
			  exit(0);
			}
			par(int i=0;i<7;i++) while(1);	// equivalent to the use of all 8 threads. Comment this line to have single thread version.
		}


	// Disconnect from flash
	fl_disconnect();

}
