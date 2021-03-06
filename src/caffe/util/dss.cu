#include "caffe/util/dss.hpp"
#include "caffe/common.hpp"

namespace caffe {

template <typename Dtype>
__global__ void compute_TSDFGPUbox(int nthreads, Dtype* tsdf_data, float* R_data, float* K_data,  float* range, 
	float grid_delta,  unsigned int *grid_range, RGBDpixel* RGBDimage,  
	unsigned int* star_end_indx_data ,unsigned int*  pc_lin_indx_data, 
	float* XYZimage,  const float* bb3d_data, int tsdf_size,int tsdf_size1,
	int tsdf_size2, int fdim, int im_w, int im_h, const int encode_type,const float scale)
{
    //const int index = threadIdx.x + blockIdx.x * blockDim.x;
    CUDA_KERNEL_LOOP(index, nthreads) {
      int volume_size = tsdf_size * tsdf_size1 * tsdf_size2;
      if (index > volume_size) return;
      float delta_x = 2 * bb3d_data[12] / float(tsdf_size);  
      float delta_y = 2 * bb3d_data[13] / float(tsdf_size1);  
      float delta_z = 2 * bb3d_data[14] / float(tsdf_size2);  
      float surface_thick = 0.1;
      const float MaxDis = surface_thick + 20;
      //printf("delta_x:%f,%f,%f\n",R_data[0],R_data[1],R_data[2]); 
      // caculate tsdf for this box
      /*
      float x = float(index % tsdf_size);
      float y = float((index / tsdf_size) % tsdf_size);   
      float z = float((index / tsdf_size / tsdf_size) % tsdf_size);
      */
      float x = float((index / (tsdf_size1*tsdf_size2))%tsdf_size) ;
      float y = float((index / tsdf_size2) % tsdf_size1);
      float z = float(index % tsdf_size2);

      for (int i = 0; i < fdim; i++){
          tsdf_data[index + i * volume_size] = 0;
      }

      // get grid world coordinate
      float temp_x = - bb3d_data[12] + (x + 0.5) * delta_x;
      float temp_y = - bb3d_data[13] + (y + 0.5) * delta_y;
      float temp_z = - bb3d_data[14] + (z + 0.5) * delta_z;

      x = temp_x * bb3d_data[0] + temp_y * bb3d_data[3] + temp_z * bb3d_data[6]
          + bb3d_data[9];
      y = temp_x * bb3d_data[1] + temp_y * bb3d_data[4] + temp_z * bb3d_data[7]
          + bb3d_data[10];
      z = temp_x * bb3d_data[2] + temp_y * bb3d_data[5] + temp_z * bb3d_data[8]
          + bb3d_data[11]; 

      // project to image plane decides the sign
      // rotate back and swap y, z and -y
      float xx =   R_data[0] * x + R_data[3] * y + R_data[6] * z;
      float zz =   R_data[1] * x + R_data[4] * y + R_data[7] * z;
      float yy = - R_data[2] * x - R_data[5] * y - R_data[8] * z;
      int ix = floor(xx * K_data[0] / zz + K_data[2]+0.5) - 1;
      int iy = floor(yy * K_data[4] / zz + K_data[5]+0.5) - 1;

      
      if (ix < 0 || ix >= im_w || iy < 0 || iy >= im_h || zz < 0.0001){
          return;
      } 

      // find the most nearby point 
      float disTosurfaceMin = MaxDis;
      int idx_min = 0;
      int x_grid = floor((x-range[0])/grid_delta);
      int y_grid = floor((y-range[1])/grid_delta);
      int z_grid = floor((z-range[2])/grid_delta);
      //grid_range =  [w,d,h];  linearInd =x(i)*d*h+y(i)*h+z(i);
      //if (x_grid < 0 || x_grid >= grid_range[0] || y_grid < 0 || y_grid >= grid_range[1] || z_grid < 0 || z_grid >= grid_range[2]){
      if (x_grid < 0 || x_grid > grid_range[0] || y_grid < 0 || y_grid > grid_range[1] || z_grid < 0 || z_grid > grid_range[2]){
          return;
      }
      int linearInd =x_grid*grid_range[1]*grid_range[2]+y_grid*grid_range[2]+z_grid;      
      int search_region =1;
      if (star_end_indx_data[2*linearInd+0]>0){
          search_region =0;
      }  
      int find_close_point = -1;

      while(find_close_point<0&&search_region<3){
        for (int iix = max(0,x_grid-search_region); iix < min((int)grid_range[0],x_grid+search_region+1); iix++){
          for (int iiy = max(0,y_grid-search_region); iiy < min((int)grid_range[1],y_grid+search_region+1); iiy++){
            for (int iiz = max(0,z_grid-search_region); iiz < min((int)grid_range[2],z_grid+search_region+1); iiz++){
                unsigned int iilinearInd = iix*grid_range[1]*grid_range[2] + iiy*grid_range[2] + iiz;

                for (int pid = star_end_indx_data[2*iilinearInd+0]-1; pid < star_end_indx_data[2*iilinearInd+1]-1;pid++){
                   
                   //printf("%d-%d\n",star_end_indx_data[2*iilinearInd+0],star_end_indx_data[2*iilinearInd+1]);
                   unsigned int p_idx_lin = pc_lin_indx_data[pid];
                   float xp = XYZimage[3*p_idx_lin+0];
                   float yp = XYZimage[3*p_idx_lin+1];
                   float zp = XYZimage[3*p_idx_lin+2];
                   // distance
                   float xd = abs(x - xp);
                   float yd = abs(y - yp);
                   float zd = abs(z - zp);
                   if (xd < 2.0 * delta_x||yd < 2.0 * delta_x|| zd < 2.0 * delta_x){
                      float disTosurface = sqrt(xd * xd + yd * yd + zd * zd);
                      if (disTosurface < disTosurfaceMin){
                         disTosurfaceMin = disTosurface;
                         idx_min = p_idx_lin;
                         find_close_point = 1;
                         //printf("x:%f,%f,%f,xp,%f,%f,%f,xd%f,%f,%f,%f\n",x,y,z,xp,yp,zp,xd,yd,zd,disTosurfaceMin);
                         
                      }
                  }
                } // for all points in this grid
              

            }
          }
        }
        search_region ++;
      }//while 
      
      float tsdf_x = MaxDis;
      float tsdf_y = MaxDis;
      float tsdf_z = MaxDis;


      float color_b =0;
      float color_g =0;
      float color_r =0;

      float xnear = 0;
      float ynear = 0;
      float znear = 0;
      if (find_close_point>0){
          
          xnear = XYZimage[3*idx_min+0];
          ynear = XYZimage[3*idx_min+1];
          znear = XYZimage[3*idx_min+2];
          tsdf_x = abs(x - xnear);
          tsdf_y = abs(y - ynear);
          tsdf_z = abs(z - znear);

          color_b = float(RGBDimage[idx_min].B)/255.0;
          color_g = float(RGBDimage[idx_min].G)/255.0;
          color_r = float(RGBDimage[idx_min].R)/255.0;

          //printf("x:%f,tsdf_x:%f,%f,%f\n",disTosurfaceMin,tsdf_x,tsdf_y,tsdf_z);          
      }


      disTosurfaceMin = min(disTosurfaceMin/surface_thick,float(1.0));
      float ratio = 1.0 - disTosurfaceMin;
      float second_ratio =0;
      if (ratio > 0.5) {
         second_ratio = 1 - ratio;
      }
      else{
         second_ratio = ratio;
      }

      if (disTosurfaceMin > 0.999){
          tsdf_x = MaxDis;
          tsdf_y = MaxDis;
          tsdf_z = MaxDis;
      }

      
      if (encode_type == 101){ 
        tsdf_x = min(tsdf_x, surface_thick);
        tsdf_y = min(tsdf_y, surface_thick);
        tsdf_z = min(tsdf_z, surface_thick);
      }
      else{
        tsdf_x = min(tsdf_x, float(2.0 * delta_x));
        tsdf_y = min(tsdf_y, float(2.0 * delta_y));
        tsdf_z = min(tsdf_z, float(2.0 * delta_z));
      }

     

      float depth_project   = XYZimage[3*(ix * im_h + iy)+1];  
      if (zz > depth_project) {
        tsdf_x = - tsdf_x;
        tsdf_y = - tsdf_y;
        tsdf_z = - tsdf_z;
        disTosurfaceMin = - disTosurfaceMin;
        second_ratio = - second_ratio;
      }

      // encode_type 
      if (encode_type == 100||encode_type == 101){
        tsdf_data[index + 0 * volume_size] = float(tsdf_x);
        tsdf_data[index + 1 * volume_size] = float(tsdf_y);
        tsdf_data[index + 2 * volume_size] = float(tsdf_z);
      }
      else if(encode_type == 102){
        tsdf_data[index + 0 * volume_size] = float(tsdf_x);
        tsdf_data[index + 1 * volume_size] = float(tsdf_y);
        tsdf_data[index + 2 * volume_size] = float(tsdf_z);
        tsdf_data[index + 3 * volume_size] = float(color_b/scale);
        tsdf_data[index + 4 * volume_size] = float(color_g/scale);
        tsdf_data[index + 5 * volume_size] = float(color_r/scale);
      }
      else if(encode_type == 103){
        tsdf_data[index + 0 * volume_size] = float(ratio);
      }

      // scale feature 
      for (int i = 0; i < fdim; i++){
          tsdf_data[index + i * volume_size] = float(scale* float(tsdf_data[index + i * volume_size]));
      }
    }
    //}// end for each index in each box
}

template <typename Dtype>
__global__ void compute_TSDFGPUbox_proj(Dtype* tsdf_data, float* R_data, float* K_data, RGBDpixel* RGBDimage, float* XYZimage,
                                      const float* bb3d_data, int tsdf_size,int tsdf_size1,int tsdf_size2, int fdim, int im_w, int im_h, const int encode_type,const float scale)
{
  const int index = threadIdx.x + blockIdx.x * blockDim.x;;
    int volume_size = tsdf_size * tsdf_size1 * tsdf_size2;
    if (index > volume_size) return;
    float delta_x = 2 * bb3d_data[12] / float(tsdf_size);  
    float delta_y = 2 * bb3d_data[13] / float(tsdf_size1);  
    float delta_z = 2 * bb3d_data[14] / float(tsdf_size2);  
    float surface_thick = 0.1;
    const float MaxDis = surface_thick + 20;

    float x = float((index / (tsdf_size1*tsdf_size2))%tsdf_size) ;
    float y = float((index / tsdf_size2) % tsdf_size1);
    float z = float(index % tsdf_size2);

    for (int i =0;i<fdim;i++){
        tsdf_data[index + i * volume_size] = float(0);
    }

    // get grid world coordinate
    float temp_x = - bb3d_data[12] + (x + 0.5) * delta_x;
    float temp_y = - bb3d_data[13] + (y + 0.5) * delta_y;
    float temp_z = - bb3d_data[14] + (z + 0.5) * delta_z;

    x = temp_x * bb3d_data[0] + temp_y * bb3d_data[3] + temp_z * bb3d_data[6]
        + bb3d_data[9];
    y = temp_x * bb3d_data[1] + temp_y * bb3d_data[4] + temp_z * bb3d_data[7]
        + bb3d_data[10];
    z = temp_x * bb3d_data[2] + temp_y * bb3d_data[5] + temp_z * bb3d_data[8]
        + bb3d_data[11]; 

    // project to image plane decides the sign
    // rotate back and swap y, z and -y
    float xx =   R_data[0] * x + R_data[3] * y + R_data[6] * z;
    float zz =   R_data[1] * x + R_data[4] * y + R_data[7] * z;
    float yy = - R_data[2] * x - R_data[5] * y - R_data[8] * z;
    int ix = floor(xx * K_data[0] / zz + K_data[2]+0.5) - 1;
    int iy = floor(yy * K_data[4] / zz + K_data[5]+0.5) - 1;

    
    if (ix < 0 || ix >= im_w || iy < 0 || iy >= im_h || zz < 0.0001){
        return;
    } 
    
    float x_project   = XYZimage[3*(ix * im_h + iy)+0];
    float y_project   = XYZimage[3*(ix * im_h + iy)+1];
    float z_project   = XYZimage[3*(ix * im_h + iy)+2]; 


    float tsdf_x = abs(x - x_project);
    float tsdf_y = abs(y - y_project);
    float tsdf_z = abs(z - z_project);

    float color_b = 0;
    float color_g = 0;
    float color_r = 0;
    if (RGBDimage!=NULL){
      color_b = float(RGBDimage[(ix * im_h + iy)].B)/255.0;
      color_g = float(RGBDimage[(ix * im_h + iy)].G)/255.0;
      color_r = float(RGBDimage[(ix * im_h + iy)].R)/255.0;
    }

    float disTosurfaceMin = sqrt(tsdf_x * tsdf_x + tsdf_y * tsdf_y + tsdf_z * tsdf_z);
    disTosurfaceMin = min(disTosurfaceMin/surface_thick,float(1.0));
    float ratio = 1.0 - disTosurfaceMin;
    float second_ratio =0;
    if (ratio > 0.5) {
       second_ratio = 1 - ratio;
    }
    else{
       second_ratio = ratio;
    }
    if (disTosurfaceMin > 0.999){
        tsdf_x = MaxDis;
        tsdf_y = MaxDis;
        tsdf_z = MaxDis;
    }

    tsdf_x = min(tsdf_x, float(2.0 * delta_x));
    tsdf_y = min(tsdf_y, float(2.0 * delta_y));
    tsdf_z = min(tsdf_z, float(2.0 * delta_z));

    if (zz > y_project) {
      tsdf_x = - tsdf_x;
      tsdf_y = - tsdf_y;
      tsdf_z = - tsdf_z;
      disTosurfaceMin = - disTosurfaceMin;
      second_ratio = - second_ratio;
    }

    // encode_type 
    if (encode_type == 0){
      tsdf_data[index + 0 * volume_size] = float(tsdf_x);
      tsdf_data[index + 1 * volume_size] = float(tsdf_y);
      tsdf_data[index + 2 * volume_size] = float(tsdf_z);
    }
    if (encode_type == 2){
      tsdf_data[index + 0 * volume_size] = float(tsdf_x);
      tsdf_data[index + 1 * volume_size] = float(tsdf_y);
      tsdf_data[index + 2 * volume_size] = float(tsdf_z);
      tsdf_data[index + 3 * volume_size] = float(color_b/scale);
      tsdf_data[index + 4 * volume_size] = float(color_g/scale);
      tsdf_data[index + 5 * volume_size] = float(color_r/scale);
    }
    // scale feature 
    for (int i = 0; i < fdim; i++){
        tsdf_data[index + i * volume_size] = float(scale* float(tsdf_data[index + i * volume_size]));
    }
}

__global__ void compute_xyzkernel(float * XYZimage, float * Depthimage, float * K, float * R){
	int ix = blockIdx.x;
	int iy = threadIdx.x;
	int height = blockDim.x;
	//
	//float depth = float(*((uint16_t*)(&(RGBDimage[iy + ix * height].D))))/1000.0;
	float depth = Depthimage[iy + ix * height];            
	// project the depth point to 3d
	float tdx = (float(ix + 1) - K[2]) * depth / K[0];
	float tdz =  - (float(iy + 1) - K[5]) * depth / K[4];
	float tdy = depth;

	XYZimage[3 * (iy + ix * height) + 0] = R[0] * tdx + R[1] * tdy + R[2] * tdz;
	XYZimage[3 * (iy + ix * height) + 1] = R[3] * tdx + R[4] * tdy + R[5] * tdz;
	XYZimage[3 * (iy + ix * height) + 2] = R[6] * tdx + R[7] * tdy + R[8] * tdz;
}

__global__ void compute_xyzkernel(float * XYZimage, RGBDpixel * RGBDimage, float * K, float * R){
    int ix = blockIdx.x;
    int iy = threadIdx.x;
    int height = blockDim.x;
    //
    //float depth = float(*((uint16_t*)(&(RGBDimage[iy + ix * height].D))))/1000.0;
    uint16_t D = (uint16_t)RGBDimage[iy + ix * height].D;
    uint16_t D_ = (uint16_t)RGBDimage[iy + ix * height].D_;
    D_ = D_<<8;
    float depth = float(D|D_)/1000.0;
    //printf("%d,%d,%f\n",RGBDimage[iy + ix * height].D,D_,depth);
    
    // project the depth point to 3d
    float tdx = (float(ix + 1) - K[2]) * depth / K[0];
    float tdz =  - (float(iy + 1) - K[5]) * depth / K[4];
    float tdy = depth;

    XYZimage[3 * (iy + ix * height) + 0] = R[0] * tdx + R[1] * tdy + R[2] * tdz;
    XYZimage[3 * (iy + ix * height) + 1] = R[3] * tdx + R[4] * tdy + R[5] * tdz;
    XYZimage[3 * (iy + ix * height) + 2] = R[6] * tdx + R[7] * tdy + R[8] * tdz;

}

__global__ void fillInBeIndexFull(unsigned int* beIndexFull, unsigned int* beIndex, unsigned int* beLinIdx, unsigned int len_beLinIdx){
     const int index = threadIdx.x + blockIdx.x * blockDim.x;
     if (index>=len_beLinIdx) {
        return;
     }
     else{
        beIndexFull[2*beLinIdx[index]+0] =  beIndex[2*index+0];
        beIndexFull[2*beLinIdx[index]+1] =  beIndex[2*index+1];
     }
}

template <typename Dtype>
void compute_TSDF_Space(Scene3D<Dtype>* scene , Box3D SpaceBox, Dtype* tsdf_data_GPU, 
    std::vector<int> grid_size, int encode_type, float scale) { 
   scene->loadData2XYZimage(); 

   float* bb3d_data;
   CUDA_CHECK(cudaMalloc(&bb3d_data,  sizeof(float)*15));
   CUDA_CHECK(cudaMemcpy(bb3d_data, SpaceBox.base, sizeof(float)*15, cudaMemcpyHostToDevice));
   unsigned int * grid_range = scene->grid_range;
   float* R_data = scene->R_GPU;
   float* K_data = scene->K_GPU;
   float* range  = scene->begin_range;
   RGBDpixel* RGBDimage = scene->RGBDimage;
   unsigned int* star_end_indx_data = scene->beIndex;
   unsigned int* pc_lin_indx_data = scene->pcIndex;
   float* XYZimage  = scene->XYZimage;

   int THREADS_NUM = 1024;
   int BLOCK_NUM = int((grid_size[1]*grid_size[2]*grid_size[3] + size_t(THREADS_NUM) - 1) / THREADS_NUM);

   compute_TSDFGPUbox<<<BLOCK_NUM,THREADS_NUM>>>(BLOCK_NUM, tsdf_data_GPU, R_data, K_data, range, scene->grid_delta, grid_range, RGBDimage, star_end_indx_data, pc_lin_indx_data, XYZimage, bb3d_data, grid_size[1],grid_size[2],grid_size[3],grid_size[0], 
                           scene->width, scene->height, encode_type, scale);

   scene-> free();
   CUDA_CHECK(cudaGetLastError());
   CUDA_CHECK(cudaFree(bb3d_data));
}

template <typename Dtype>
void compute_TSDF(std::vector<Scene3D<Dtype>*> *chosen_scenes_ptr, std::vector<int> *chosen_box_id, 
                  Dtype* datamem, std::vector<int> grid_size, int encode_type, float scale) {
  // for each scene 
  int totalcounter = 0;
  float tsdf_size = grid_size[1];
  if (grid_size[1] != grid_size[2] || grid_size[1] != grid_size[3]){
      std::cerr << "grid_size[1] != grid_size[2] || grid_size[1] != grid_size[3]" <<std::endl;
      exit(1);
  }

  int numeltsdf = grid_size[0]*tsdf_size*tsdf_size*tsdf_size;
  int BLOCK_NUM = tsdf_size * tsdf_size * tsdf_size;
  float* bb3d_data;

  //int tmpD; cudaGetDevice(&tmpD); std::cout<<"GPU at LINE "<<__LINE__<<" = "<<tmpD<<std::endl;
  //checkCUDA(__LINE__,cudaDeviceSynchronize());
  CUDA_CHECK(cudaMalloc(&bb3d_data,  sizeof(float)*15));
  
  Scene3D<Dtype>* scene_prev = NULL;
  for (int sceneId = 0;sceneId<(*chosen_scenes_ptr).size();sceneId++){
      // caculate in CPU mode
      //compute_TSDFCPUbox(tsdf_data,&((*chosen_scenes_ptr)[sceneId]),boxId,grid_size,encode_type,scale);
      // caculate in GPU mode
      Scene3D<Dtype>* scene = (*chosen_scenes_ptr)[sceneId];
      // perpare scene
      if (scene!=scene_prev){
          if (scene_prev!=NULL){
             scene_prev -> free();
          }
          scene->loadData2XYZimage(); 
      }
      
      int boxId = (*chosen_box_id)[sceneId];
      CUDA_CHECK(cudaMemcpy(bb3d_data, scene->objects[boxId].base, sizeof(float)*15, cudaMemcpyHostToDevice));

      unsigned int * grid_range = scene->grid_range;
      float* R_data = scene->R_GPU;
      float* K_data = scene->K_GPU;
      float* range  = scene->begin_range;
      
      RGBDpixel* RGBDimage = scene->RGBDimage;
      unsigned int* star_end_indx_data = scene->beIndex;
      unsigned int* pc_lin_indx_data = scene->pcIndex;
      float* XYZimage  = scene->XYZimage;
      
      // output
      Dtype * tsdf_data = &datamem[totalcounter*numeltsdf];

      if (encode_type > 99){
          compute_TSDFGPUbox<<<CAFFE_GET_BLOCKS(BLOCK_NUM),CAFFE_CUDA_NUM_THREADS>>>(BLOCK_NUM, tsdf_data, R_data, K_data, range, scene->grid_delta,   grid_range, RGBDimage, star_end_indx_data, pc_lin_indx_data, XYZimage, bb3d_data, grid_size[1],grid_size[2],grid_size[3], grid_size[0], scene->width, scene->height, encode_type, scale);

      }
      else{
        compute_TSDFGPUbox_proj<<<CAFFE_GET_BLOCKS(BLOCK_NUM), CAFFE_CUDA_NUM_THREADS>>>(tsdf_data, R_data, K_data, RGBDimage, XYZimage,
                                                           bb3d_data, grid_size[1],grid_size[2],grid_size[3], grid_size[0], 
                                                           scene->width, scene->height, encode_type, scale);
      }
      
      CUDA_CHECK(cudaDeviceSynchronize());
      CUDA_CHECK(cudaGetLastError());

      ++totalcounter;
      scene_prev = scene;
  }
  CUDA_CHECK(cudaFree(bb3d_data));
  
  // free the loaded images
  for (int sceneId = 0;sceneId<(*chosen_scenes_ptr).size();sceneId++){
      (*chosen_scenes_ptr)[sceneId]->free();
  }
   
}

template <typename Dtype>
void Scene3D<Dtype>::compute_xyzGPU() {
    if (!GPUdata){
        std::cout<< "Data is not at GPU cannot compute_xyz at GPU"<<std::endl;
    }
    if (XYZimage!=NULL){
        std::cout<< "XYZimage!=NULL"<<std::endl;
    }
    CUDA_CHECK(cudaMalloc(&XYZimage, sizeof(float)*width*height*3));
    compute_xyzkernel<<<width, height>>>(XYZimage, RGBDimage, K_GPU, R_GPU);
}

template <typename Dtype>
void Scene3D<Dtype>::cpu2gpu()
{
	if (!GPUdata){
		if (beIndex!=NULL){
			unsigned int* beIndexCPU = beIndex;
           //checkCUDA(__LINE__,cudaDeviceSynchronize());
			CUDA_CHECK(cudaMalloc(&beIndex, sizeof(unsigned int)*len_beIndex));
           //checkCUDA(__LINE__,cudaDeviceSynchronize());
			CUDA_CHECK(cudaMemcpy(beIndex, beIndexCPU,sizeof(unsigned int)*len_beIndex, cudaMemcpyHostToDevice));
			delete [] beIndexCPU;
		}
		else{
			std::cout << "beIndex is NULL"<<std::endl;
		}

		if (beLinIdx!=NULL){
			unsigned int* beLinIdxCPU = beLinIdx;
           //checkCUDA(__LINE__,cudaDeviceSynchronize());
			CUDA_CHECK(cudaMalloc(&beLinIdx, sizeof(unsigned int)*len_beLinIdx));
           //checkCUDA(__LINE__,cudaDeviceSynchronize());
			CUDA_CHECK(cudaMemcpy(beLinIdx, beLinIdxCPU,sizeof(unsigned int)*len_beLinIdx, cudaMemcpyHostToDevice));
			delete [] beLinIdxCPU;
		}
		else{
			std::cout << "beLinIdx is NULL"<<std::endl;
		}

       // make it to full matrix to skip searching 
		unsigned int * beIndexFull;
		unsigned int sz = 2*sizeof(unsigned int)*(grid_range[0]+1)*(grid_range[1]+1)*(grid_range[2]+1);
		CUDA_CHECK(cudaMalloc(&beIndexFull, sz));
		CUDA_CHECK(cudaMemset(beIndexFull, 0, sz));
		int THREADS_NUM = 1024;
		int BLOCK_NUM = int((len_beLinIdx + size_t(THREADS_NUM) - 1) / THREADS_NUM);
		fillInBeIndexFull<<<BLOCK_NUM, THREADS_NUM>>>(beIndexFull, beIndex, beLinIdx,len_beLinIdx);
		CUDA_CHECK(cudaGetLastError());
		CUDA_CHECK(cudaFree(beIndex));      beIndex = NULL;
		CUDA_CHECK(cudaFree(beLinIdx));     beLinIdx = NULL;
		beIndex = beIndexFull;

		if (pcIndex!=NULL){
			unsigned int* pcIndexCPU = pcIndex;
			CUDA_CHECK(cudaMalloc(&pcIndex, sizeof(unsigned int)*len_pcIndex));
			CUDA_CHECK(cudaMemcpy(pcIndex, pcIndexCPU,sizeof(unsigned int)*len_pcIndex, cudaMemcpyHostToDevice));
			delete [] pcIndexCPU;
		}
		else{
			std::cout << "pcIndexCPU is NULL"<<std::endl;
		}


		if (RGBDimage!=NULL){
			RGBDpixel* RGBDimageCPU = RGBDimage;
			CUDA_CHECK(cudaMalloc(&RGBDimage, sizeof(RGBDpixel)*width*height));
			CUDA_CHECK(cudaMemcpy( RGBDimage, RGBDimageCPU, sizeof(RGBDpixel)*width*height, cudaMemcpyHostToDevice));
			delete [] RGBDimageCPU;
		}
		else{
			std::cout << "RGBDimage is NULL"<<std::endl;
		}

		if (grid_range!=NULL){ 
			unsigned int * grid_rangeCPU = grid_range;
			CUDA_CHECK(cudaMalloc(&grid_range, sizeof(unsigned int)*3));
			CUDA_CHECK(cudaMemcpy(grid_range, grid_rangeCPU, 3*sizeof(unsigned int), cudaMemcpyHostToDevice));
			delete [] grid_rangeCPU;
		}
		else{
			std::cout << "grid_range is NULL"<<std::endl;
		}

		if (begin_range!=NULL){ 
			float * begin_rangeCPU = begin_range;
			CUDA_CHECK(cudaMalloc(&begin_range, sizeof(float)*3));
			CUDA_CHECK(cudaMemcpy(begin_range, begin_rangeCPU, sizeof(float)*3, cudaMemcpyHostToDevice));
			delete [] begin_rangeCPU;
		}
		else{
			std::cout << "grid_range is NULL"<<std::endl;
		}


		CUDA_CHECK(cudaMalloc(&K_GPU, sizeof(float)*9));
		CUDA_CHECK(cudaMemcpy(K_GPU, (float*)K, sizeof(float)*9, cudaMemcpyHostToDevice));


		CUDA_CHECK(cudaMalloc(&R_GPU, sizeof(float)*9));
		CUDA_CHECK(cudaMemcpy(R_GPU, (float*)R, sizeof(float)*9, cudaMemcpyHostToDevice)); 

		GPUdata = true;

	}
}

template <typename Dtype>
void Scene3D<Dtype>::free(){
	if (GPUdata){
      //std::cout<< "free GPUdata"<<std::endl;
		if (RGBDimage   !=NULL) {CUDA_CHECK(cudaFree(RGBDimage));    RGBDimage = NULL;}
		if (beIndex     !=NULL) {CUDA_CHECK(cudaFree(beIndex));      beIndex = NULL;}
		if (beLinIdx    !=NULL) {CUDA_CHECK(cudaFree(beLinIdx));     beLinIdx = NULL;}
		if (pcIndex     !=NULL) {CUDA_CHECK(cudaFree(pcIndex));      pcIndex = NULL;}
		if (XYZimage    !=NULL) {CUDA_CHECK(cudaFree(XYZimage));     XYZimage = NULL;}
		if (R_GPU       !=NULL) {CUDA_CHECK(cudaFree(R_GPU));        R_GPU = NULL;}
		if (K_GPU       !=NULL) {CUDA_CHECK(cudaFree(K_GPU));        K_GPU = NULL;}
		if (grid_range  !=NULL) {CUDA_CHECK(cudaFree(grid_range));   grid_range = NULL;}
		if (begin_range !=NULL) {CUDA_CHECK(cudaFree(begin_range));  begin_range = NULL;}
		GPUdata = false;
	}
	else{
      //std::cout<< "free CPUdata"<<std::endl;
		if (RGBDimage   !=NULL) {delete [] RGBDimage;    RGBDimage   = NULL;}
		if (beIndex     !=NULL) {delete [] beIndex;      beIndex     = NULL;}
		if (beLinIdx    !=NULL) {delete [] beLinIdx;     beLinIdx    = NULL;}
		if (pcIndex     !=NULL) {delete [] pcIndex;      pcIndex     = NULL;}
		if (XYZimage    !=NULL) {delete [] XYZimage;     XYZimage    = NULL;}
		if (grid_range  !=NULL) {delete [] grid_range;   grid_range  = NULL;}
		if (begin_range !=NULL) {delete [] begin_range;  begin_range = NULL;}
	}
}

// Explicit instantiation
template void compute_TSDF<float>(std::vector<Scene3D<float>*> *chosen_scenes_ptr, std::vector<int> *chosen_box_id, 
                  float* datamem, std::vector<int> grid_size, int encode_type, float scale);
template void compute_TSDF<double>(std::vector<Scene3D<double>*> *chosen_scenes_ptr, std::vector<int> *chosen_box_id, 
                  double* datamem, std::vector<int> grid_size, int encode_type, float scale);                  
}