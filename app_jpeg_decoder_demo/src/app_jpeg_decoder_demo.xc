#include <platform.h>
#include <stdio.h>
#include <print.h>
#include <assert.h>

#include "loader.h"
#include "sdram.h"
#include "lcd.h"
#include "display_controller.h"
#include "touch_controller_lib.h"
#include "touch_controller_impl.h"
#include "jpeg_decoder.h"
#include "conf.h"


on tile[0] : lcd_ports lcdports = {
  XS1_PORT_1I, XS1_PORT_1L, XS1_PORT_16B, XS1_PORT_1J, XS1_PORT_1K, XS1_CLKBLK_2 };
on tile[0] : sdram_ports sdramports = {
  XS1_PORT_16A, XS1_PORT_1B, XS1_PORT_1G, XS1_PORT_1C, XS1_PORT_1F, XS1_CLKBLK_1 };
on tile[0] : touch_controller_ports touchports = {
		XS1_PORT_1E, XS1_PORT_1H, 1000, XS1_PORT_1D };


// Load JPEG images from PC to SDRAM
static void load_image(chanend c_server, chanend c_loader, unsigned image_no, unsigned image_handle) {
  unsigned buffer[(MAX_JPG_SIZE+3)/4]={0};
  char temp;

  for(unsigned j=0;j<imgSize[image_no];j++){
	  c_loader :> temp;
	  buffer[j/4] = ((unsigned)temp << ((j%4)*8)) | buffer[j/4];
  }

  image_write_line(c_server, 0, image_handle, buffer);
  wait_until_idle(c_server, buffer);

}


// Send JPG image to decoder
void send_jpg_to_decoder(chanend c_jpg, unsigned buffer[], int img_size){
	unsigned temp;
	unsigned char jpg;

	for(unsigned j=0;j<img_size;j++){
		temp = buffer[j/4];
		jpg = (temp>>((j%4)*8)) & 0xff;
		c_jpg <: jpg;
	}
}


// Receive RGB565 from the decoder
void receive_rgb_and_centered(chanend c_rgb, chanend c_server, unsigned fb_handle){
	unsigned buf[LCD_ROW_WORDS];
	unsigned imgHeight, imgWidth, MCUheight, MCUwidth;
	unsigned startRow, startCol;
	short rgb;

	// Read image dimensions and MCU dimensions from the channel
	c_rgb :> imgHeight;
	assert(imgHeight<=LCD_HEIGHT);
	c_rgb :> imgWidth;
	assert (imgWidth<=LCD_WIDTH);
	c_rgb :> MCUheight;
	c_rgb :> MCUwidth;

	// Read RGB565 values of pixels from the channel, center for LCD, write to alternate SDRAM frame buffer
	startRow = (LCD_HEIGHT-imgHeight)/2;
	startCol = (LCD_WIDTH-imgWidth)/2;

	for (int line=0; line<LCD_HEIGHT; line++){
		for (int c=0; c<LCD_ROW_WORDS; c++)
			buf[c] = 0;
		image_write_line(c_server, line, fb_handle, buf);
		wait_until_idle(c_server, buf);
	}

	for (int MCUrow=0; MCUrow<((imgHeight+MCUheight-1)/MCUheight); MCUrow++)
		for (int MCUcol=0; MCUcol<((imgWidth+MCUwidth-1)/MCUwidth); MCUcol++)
			for (int r=0; r<MCUheight; r++){

				int line = startRow+(MCUrow*MCUheight)+r;
				if (line<startRow+imgHeight){
					image_read_line(c_server, line, fb_handle, buf);
					wait_until_idle(c_server, buf);

					for (int c=0; c<MCUwidth; c++){
						int bufCol = startCol+(MCUcol*MCUwidth)+c;
						if (bufCol<startCol+imgWidth){
							c_rgb :> rgb;
							if (bufCol%2==0)
								buf[bufCol/2] = rgb;
							else
								buf[bufCol/2]= rgb<<16 | buf[bufCol/2];
						}
					}

				image_write_line(c_server, line, fb_handle, buf);
				wait_until_idle(c_server, buf);
				}
			}
}


void store_decoded_centered_image(chanend c_server, unsigned image_no, unsigned image_handle, unsigned fb_handle)
{

	chan c_jpg, c_rgb;
	unsigned buffer[(MAX_JPG_SIZE+3)/4], buf[LCD_ROW_WORDS];

	// Init frame buffer
    for (int line=0; line<LCD_HEIGHT; line++){
    	for (int c=0; c<LCD_ROW_WORDS; c++)
    		buf[c] = 0;
    	image_write_line(c_server, line, fb_handle, buf);
    	wait_until_idle(c_server, buf);
    }

	// Read JPG image from SDRAM
    image_read_line(c_server, 0, image_handle, buffer);
	wait_until_idle(c_server,buffer);

	par {
		jpeg_decoder(c_jpg, c_rgb);
		send_jpg_to_decoder(c_jpg, buffer, imgSize[image_no]);
		receive_rgb_and_centered(c_rgb, c_server, fb_handle);
	}

	frame_buffer_commit(c_server, fb_handle);
}



void app(chanend server){
  unsigned fb_index = 0, frame_buffer[2];
  unsigned image_no = 0, image[IMAGE_COUNT];
  chan c_loader;

  par{
	  for(unsigned i=0;i<IMAGE_COUNT;i++){
		  unsigned size = (imgSize[i]+3)/4;
		  image[i] = register_image(server, size, 1);
		  load_image(server, c_loader, i, image[i]);
	  }
	  loader(c_loader);
  }

  frame_buffer[0] = register_image(server, LCD_ROW_WORDS, LCD_HEIGHT);
  frame_buffer[1] = register_image(server, LCD_ROW_WORDS, LCD_HEIGHT);

  frame_buffer_init(server, frame_buffer[0]);
  touch_lib_init(touchports);
  printstrln("****** Please touch the LCD screen   ******");
  printstrln("****** to display decoded JPG image  ******");

  while(1){
    unsigned x=0,y=0;
    touch_lib_req_next_coord(touchports,x,y);

    fb_index = 1-fb_index;
    store_decoded_centered_image(server,image_no,image[image_no],frame_buffer[fb_index]);

    image_no = (image_no+1)%IMAGE_COUNT;
  }

}


void main(){
	chan c1,c2,c3;

	par{
		on tile[0]: app(c1);
		on tile[0]: display_controller(c1,c2,c3);
		on tile[0]: lcd_server(c2,lcdports);
		on tile[0]: sdram_server(c3,sdramports);
//		on tile[0]: par(int i=0;i<4;i++) while(1);

	}

}
