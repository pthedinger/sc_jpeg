/********************************************************************************
 * JPEG decoder: Receives contents of JPEG file as unsigned char from a channel and
 *               Sends height, width and decoded RGB565 values as unsigned short to another channel
 ********************************************************************************/

#include <platform.h>
#include <stdlib.h>
#include <stdio.h>
#include <print.h>
#include "jpeg_decoder.h"
#include "jpeg_conf.h"



/* Write decoded RGB565 values in row-order to channel */

void write_rgb565_to_channel( chanend chan_rgb565, unsigned row, unsigned col, short rgb[], unsigned char samp_fact, unsigned height, unsigned width){
	unsigned r,c,MCUwidth,MCUheight;
//	unsigned short temp[16][MAX_WIDTH];

	switch (samp_fact){
	case YUV420: {MCUwidth = 16; MCUheight = 16; break;}
	case YUV422: {MCUwidth = 16; MCUheight = 8; break;}
	case YUV444: {MCUwidth = 8; MCUheight = 8; break;}
	}	// switch

	if (row==0 && col==0){
		chan_rgb565 <: height;
		chan_rgb565 <: width;
		chan_rgb565 <: MCUheight;
		chan_rgb565 <: MCUwidth;
	}

//printf("row=%d col=%d\n",row,col);
//printstrln("row ....... col");
	for (r=0;r<MCUheight;r++)
		for (c=0;c<MCUwidth;c++){
			if ((col+c)<width && (row+r)<height){
				chan_rgb565 <: rgb[r*MCUwidth+c];
//printhexln(rgb[r*MCUwidth+c]);
			}
		}

}


/*
 * getByte returns a byte from the jpeg. It must be used sequentially,
 */
#pragma unsafe arrays
inline unsigned char getByte(chanend c_jpeg){
  	unsigned char data; //Image data

  	// Read a byte from a channel
  	c_jpeg :> data;
//printhexln(data);
  	return data;
}

//does the same as above but with a short
#pragma unsafe arrays
unsigned short getShort(chanend c_jpeg){
  	unsigned char dataH,dataL; //Image data
  	unsigned short data;

  	// READ two bytes of JPG IMAGE data from the channel
  	c_jpeg :> dataH;
  	c_jpeg :> dataL;
  	data = dataH<<8 | dataL;
//printhexln(data);
     return data;
}

/* Fetches one page from flash */
#pragma unsafe arrays
inline unsigned char getDataArray(chanend c_jpeg, unsigned offset, unsigned char buf[]){

	for (int i=0; i<65; i++)
		c_jpeg :> buf[i];

    return buf[0];
}

// unpack the DQT into a table
#pragma unsafe arrays
static inline unsigned DecodeDQT(chanend c_jpeg, unsigned offset, unsigned char qtab[4][64]) {
  unsigned char buf [65];
  unsigned length = getShort(c_jpeg);
//printf ("\n len = %d\n",length);
  offset += 2;
  while (length >= 65) {
	unsigned char i = getDataArray(c_jpeg,offset,buf);
//printf ("\n%x\n",i);
    for (unsigned index = 0; index < 64; ++index) {
    	qtab[i][index] = buf[index+1];
//printf ("%d ",buf[index+1]);
    }
//printf ("\n");
    offset += 65;
    length -= 65;
  }
  return offset;
}

//read the image definition stuff and save it in the components structure
#pragma unsafe arrays
static inline unsigned DecodeHuffBaselineDCT(chanend c_jpeg, unsigned offset, stComps &components) {
  unsigned length = getShort(c_jpeg);
  unsigned precision = getByte(c_jpeg);
  unsigned height = getShort(c_jpeg);
  unsigned width = getShort(c_jpeg);
  unsigned num_components = getByte(c_jpeg);

  components.height = height;
  components.width = width;
//printf("Height & Width %d %d\n",height,width);

#if JPEG_DECODER_ERROR_CHECK
  if (precision != 8){
    //fail
	  printf ("\n Error: Precision not equal to 8\n");
  }
  if  (num_components !=3) {
    //fail
	  printf ("\n Error: No. of components not equal to 3\n");
  }
#endif
  for(unsigned i = offset + 8; i< offset + 8 + 3*num_components; i+=3){
    unsigned id =  getByte(c_jpeg);
    components.sampling_factors[id-1] = getByte(c_jpeg);
//printf("\n SF[%d] = %x \n",id-1,components.sampling_factors[id-1]);
    components.qt_table[id-1] = getByte(c_jpeg);
  }
  return offset + length;
}


//read the huffman tables out of their compressed form into a table
#pragma unsafe arrays
static inline unsigned DecodeHuffmanTableDef(chanend c_jpeg, unsigned offset, unsigned huffTableSize[4],
    huffEntry huffTable[4][HUF_TBL_SIZE]) {

  unsigned length = getShort(c_jpeg);
  unsigned endOfSection = offset + length;
  unsigned count[16];
  offset += 2;
  while (offset < endOfSection) {
    //the total number of codes must be less than 256
    int hufcounter = 0;
    int codelengthcounter = 1;
    unsigned tblID = getByte(c_jpeg);
    unsigned ht_number = tblID&0xf;
    unsigned ac_dc = (tblID>>4)&0x1;
    unsigned tblIndex = ac_dc | (ht_number<<1);
    unsigned symbol_index = 16;
    unsigned entry = 0;
    offset += 1;
    huffTableSize[tblIndex] = length - symbol_index;

//printf ("\n");
    for (unsigned i = 0; i < 16; i++)
    	count[i] = getByte(c_jpeg);

    for (unsigned i = 0; i < 16; i++) {
      unsigned length = i + 1;
      for (unsigned j = 0; j < count[i]; j++) {
        unsigned symbol = getByte(c_jpeg);
        while (1) {
          if (length == codelengthcounter) {
            huffTable[tblIndex][entry].length = length;
            huffTable[tblIndex][entry].code = hufcounter;
            huffTable[tblIndex][entry].symbol = symbol;
//printf ("%x ",symbol);
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
void initStream(chanend c_jpeg, unsigned offset) {
  unsigned char t;

  g_streamOffset = offset;
  g_bitOffset = 0;

  t = getByte(c_jpeg);
  g_stream_buffer = t<<24;
  g_streamOffset = g_streamOffset + 1 + (t == 0xff);

  if (t==0xff){
	  t = getByte(c_jpeg);
	  t = getByte(c_jpeg);
  }
  else
	  t = getByte(c_jpeg);
  g_stream_buffer |= t<<16;
  g_streamOffset = g_streamOffset + 1 + (t == 0xff);

  if (t==0xff){
	  t = getByte(c_jpeg);
	  t = getByte(c_jpeg);
  }
  else
	  t = getByte(c_jpeg);
  g_stream_buffer |= t<<8;
  g_streamOffset = g_streamOffset + 1 + (t == 0xff);

  if (t==0xff){
	  t = getByte(c_jpeg);
	  t = getByte(c_jpeg);
  }
  else
	  t = getByte(c_jpeg);
  g_stream_buffer |= t;
  g_streamOffset = g_streamOffset + 1 + (t == 0xff);

  if (t==0xff)
	  t = getByte(c_jpeg);
}

//get the latest 16 bits from the head of the stream
static inline unsigned short getStream() {
  return (unsigned short)(g_stream_buffer>>(16-g_bitOffset));
}

static inline int advanceStream(chanend c_jpeg, char bits_matched) {
  unsigned short t;
  g_bitOffset += bits_matched;
  if(g_bitOffset<16) return 0;
  while (g_bitOffset > 8) {
    g_bitOffset -= 8;
    g_stream_buffer <<= 8;
    t = getByte(c_jpeg);
    g_stream_buffer |= t;
    g_streamOffset = g_streamOffset + 1 + (t == 0xff);
    if ( (t==0xff)&&(getByte(c_jpeg)==0xd9) ) return 1;
  }
  return 0;
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
static void DecodeChannel(chanend c_jpeg, short channel[64],
    const huffEntry huffTable[4][HUF_TBL_SIZE], unsigned dc_table, unsigned ac_table, short &prevDC,
    const unsigned char qt[64]) {
  unsigned char symbol;
  unsigned i;
  unsigned short next16bits = getStream();
  unsigned num_matched;

  i = 0;

  num_matched = matchCode(next16bits, huffTable[dc_table], symbol);

  if (advanceStream(c_jpeg, num_matched)) return;
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
    if (advanceStream(c_jpeg, bottombits)) return;
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
    if (advanceStream(c_jpeg, num_matched)) return;
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
    if (advanceStream(c_jpeg, bottombits)) return;
    next16bits = getStream();
    i+=topbits;
    channel[dezigzag[i]] = dc * qt[i];
    }
    i++;
    num_matched = matchCode(next16bits, huffTable[ac_table], symbol);
  }

  if (advanceStream(c_jpeg, num_matched)) return;
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
int DecodeScan(chanend c_jpeg, chanend chan_rgb565, unsigned offset,short res_int_mcus,
    const unsigned huffTableSize[4], const huffEntry huffTable[4][HUF_TBL_SIZE],
    const unsigned char qt[4][64], stComps &components) {

  short restart_marker, prevDC = 0, prevDCCr = 0, prevDCCb = 0;
  unsigned mcu=0, mcu_count;	// mcu is minimum coded unit.
  unsigned col = 0, row = 0;
  short RGB[64*4];	// Second dimension: 64*4 used for 4:2:0; 64*2 used for 4:2:2; 64 used for 4:4:4.


  if (components.sampling_factors[0]==YUV420)  // 4:2:0 chroma subsampling
	  mcu_count = ((components.height+15)/16) * ((components.width+15)/ 16);
  else if (components.sampling_factors[0]==YUV422)	// 4:2:2 chroma subsampling
	  mcu_count = ((components.height+7)/8) * ((components.width+15)/16);
  else if (components.sampling_factors[0]==YUV444)	// 4:4:4 chroma subsampling
	  mcu_count = ((components.height+7)/8) * ((components.width+7)/8);

//printf ("mcu count = %d RSI = %d", mcu_count,res_int_mcus);
  init_idct();
  initStream(c_jpeg, offset);

//printf ("\n Init over \n");
  while (mcu < mcu_count) {

	unsigned ac_table_index = components.ac_table[Y];
    unsigned dc_table_index = components.dc_table[Y];
    unsigned qt_index = components.qt_table[Y];
    	DecodeChannel(c_jpeg, components.Y[0], huffTable, dc_table_index, ac_table_index, prevDC, qt[qt_index]);
//printstrln ("Y0 decoded");
    if (components.sampling_factors[0]==YUV422 || components.sampling_factors[0]==YUV420)
    	DecodeChannel(c_jpeg, components.Y[1], huffTable, dc_table_index, ac_table_index, prevDC, qt[qt_index]);
    if (components.sampling_factors[0]==YUV420){
    	DecodeChannel(c_jpeg, components.Y[2], huffTable, dc_table_index, ac_table_index, prevDC, qt[qt_index]);
    	DecodeChannel(c_jpeg, components.Y[3], huffTable, dc_table_index, ac_table_index, prevDC, qt[qt_index]);
    }
//printstrln ("Y decoded");

    ac_table_index = components.ac_table[Cb];
    dc_table_index = components.dc_table[Cb];
    qt_index = components.qt_table[Cb];
    DecodeChannel(c_jpeg, components.Cb, huffTable, dc_table_index, ac_table_index, prevDCCb, qt[qt_index]);
//printstrln ("Cb decoded");

    ac_table_index = components.ac_table[Cr];
    dc_table_index = components.dc_table[Cr];
    qt_index = components.qt_table[Cr];
    DecodeChannel(c_jpeg, components.Cr, huffTable, dc_table_index, ac_table_index, prevDCCr, qt[qt_index]);
//printstrln ("Cr decoded");

    	idct(components.Y[0]);
    if (components.sampling_factors[0]==YUV422 || components.sampling_factors[0]==YUV420)
    	idct(components.Y[1]);
    if (components.sampling_factors[0]==YUV420){
    	idct(components.Y[2]);
    	idct(components.Y[3]);
    }
    	idct(components.Cb);
    	idct(components.Cr);
//printstrln ("idct done");

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
      	  RGB[r] = YCbCr_to_RGB565(Y0, Cb, Cr);
      if (components.sampling_factors[0]==YUV422 || components.sampling_factors[0]==YUV420)
      	  RGB[r+1] = YCbCr_to_RGB565(Y1, Cb, Cr);
      if (components.sampling_factors[0]==YUV420){
      	  RGB[r+16] = YCbCr_to_RGB565(Y2, Cb, Cr);
      	  RGB[r+17] = YCbCr_to_RGB565(Y3, Cb, Cr);
      }
    }	// for

    // Write decoded output to channel
//printstr("MCU="); printintln(mcu);
    write_rgb565_to_channel(chan_rgb565, row, col, RGB, components.sampling_factors[0], components.height, components.width);
//printf ("\n MCU written to channel at row %d col %d\n",row,col);

    mcu++;

	// Restart marker check
    if (res_int_mcus) if (mcu%res_int_mcus==0){
	  restart_marker = getShort(c_jpeg);
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
}


//top level decode function.
int jpeg_decoder(chanend chan_jpeg, chanend chan_rgb565) {
  unsigned huffTableSize[4];
  huffEntry huffTable[4][HUF_TBL_SIZE];
  unsigned char qt[4][64],temp_char;
  stComps components;
  unsigned offset = 0;
  unsigned short marker;
  short res_int_MCUs;

  marker = getShort(chan_jpeg);
  offset += 2;
#if (JPEG_DECODER_ERROR_CHECK)
  if (marker != 0xffd8){	// Start of image check
	  printstr ("\n Start of Image marker missing \n");
    return -1;
  }
#endif

  marker = getShort(chan_jpeg);
  offset += 2;
  while (marker !=  0xffd9) {	// loop until end of image

    marker = getShort(chan_jpeg);
    offset += 2;

//printf ("\n %x\n",marker);

    switch (marker) {
    case QuantTableDef: {
      offset = DecodeDQT(chan_jpeg, offset, qt);
//printf("offset=%d\n",offset);
//printstr("\nQuantization table\n");
      break;
    }
    case HuffBaselineDCT: {
      offset = DecodeHuffBaselineDCT(chan_jpeg, offset, components);
//printf("offset=%d\n",offset);
//printstr("\nHuffBaselineDCT\n");
      break;
    }
    case HuffmanTableDef: {
      offset = DecodeHuffmanTableDef(chan_jpeg, offset, huffTableSize, huffTable);
//printf("offset=%d\n",offset);
//printstr("\nHuffmanTableDef\n");
      break;
    }
    case RestartIntervalDef: {
    	offset+=2;
    	res_int_MCUs = getShort(chan_jpeg);
    	offset+=2;
//printf("offset=%d\n",offset);
//printf("\nRestartIntervalDef %d\n",res_int_MCUs);
      break;
    }
    case StartOfScan: {
      unsigned length =getShort(chan_jpeg);
      unsigned num_components = getByte(chan_jpeg);
      components.count = num_components;
      for(unsigned i=0;i<num_components;i++){
        unsigned char component_id = getByte(chan_jpeg);
        unsigned tblInfo = getByte(chan_jpeg);
        unsigned char ac_table = tblInfo&0xf;
        unsigned char dc_table = tblInfo>>4;
        components.ac_table[component_id-1] = 1 | (ac_table<<1) ;
        components.dc_table[component_id-1] = 0 | (dc_table<<1) ;
      }
      for (unsigned i=3+2*num_components; i<length; i++)
    	  temp_char = getByte(chan_jpeg);
//printf("offset=%d num_comps=%d length=%d\n",offset,num_components,length);
      offset += length;
      DecodeScan(chan_jpeg, chan_rgb565, offset, res_int_MCUs, huffTableSize, huffTable, qt, components);
//printstr("\n Decode Scan over\n");
      return;
    }
    default: {
      //skip unnessessary sections
//printf("\nDefault\n");
      break;
    }
    }	// switch

  }	// while
}

