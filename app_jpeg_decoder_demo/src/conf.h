
#ifndef CONF_H_
#define CONF_H_


//#define IMAGE_COUNT (11)
//static char images[IMAGE_COUNT][30] = {"stream.jpg","jeep.jpg","rainbow-fishes.jpg", "c4lenna100m0.jpg","c2forest70m0.jpg","c1audio90m0.jpg","rainbow-fishes-crop.jpg","1.jpg", "2.jpg","4.jpg","11.jpg","22.jpg","44.jpg"};
//static int imgSize[IMAGE_COUNT] = {9059,9663,1402,567,3983,567,664,591,619,685,599,639};	// Size in bytes
#define IMAGE_COUNT (3)
static char images[IMAGE_COUNT][30] = {"rainbow-fishes.jpg","c2forest70m0.jpg","1.jpg"};
static int imgSize[IMAGE_COUNT] = {9663,567,664};	// Size in bytes
#define MAX_JPG_SIZE 10000

#endif /* CONF_H_ */
