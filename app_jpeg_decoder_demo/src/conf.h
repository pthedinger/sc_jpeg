
#ifndef CONF_H_
#define CONF_H_


//#define IMAGE_COUNT ( )
//static char images[IMAGE_COUNT][30] = {"images/lenna.jpg","images/audio.jpg","images/rainbow-fishes444.jpg","images/rainbow-fishes422.jpg","jeep.jpg","rainbow-fishes420.jpg", "images/c1lenna100m0.jpg", "images/c2lenna100m0.jpg", "c4lenna100m0.jpg","c2forest70m0.jpg","c1audio90m0.jpg","rainbow-fishes-crop.jpg","1.jpg", "2.jpg","4.jpg","11.jpg","22.jpg","44.jpg"};
//static int imgSize[IMAGE_COUNT] = {7824,5971,16453,14205,10366,9663,1500,1281,1402,567,3983,567,664,591,619,685,599,639};	// Size in bytes
#define IMAGE_COUNT (4)
static char images[IMAGE_COUNT][30] = {"images/rainbow-fishes420.jpg","images/1.jpg","images/c2forest70m0.jpg","images/2.jpg"};
static int imgSize[IMAGE_COUNT] = {9663,664,567,591};	// Size in bytes
#define MAX_JPG_SIZE 10000

#endif /* CONF_H_ */
