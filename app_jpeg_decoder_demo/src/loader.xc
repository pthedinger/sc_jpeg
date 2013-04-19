
#include <syscall.h>
#include <stdio.h>
#include <stdlib.h>
#include "loader.h"
#include "conf.h"


void loader(chanend c){
//  char ch[1];
	char ch[MAX_JPG_SIZE];
	unsigned k=0;

	while(k<IMAGE_COUNT){

	  int fp =_open(images[k], O_RDONLY, 0);
	  if(fp < 0){
		  iprintf("Error: Couldn't open %s\n", images[k]);
	  }

	  _read(fp, ch, imgSize[k]);
	  for (int i=0; i<imgSize[k]; i++){
//printf("%x\n",ch[i]);
		  c <: ch[i];
	  }
/*
	  _read(fp, ch, 1);
	  while (ch[0] != EOF){
printf("%x\n",ch[0]);
		c <: ch[0];
		_read(fp, ch, 1);
	  }
*/

	  _close(fp);
	  k++;
//printf("%s ",images[k]);
	}

}

