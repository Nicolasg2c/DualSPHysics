//HEAD_DSPH
/*
<DUALSPHYSICS>  Copyright (c) 2018 by Dr Jose M. Dominguez et al. (see http://dual.sphysics.org/index.php/developers/). 

EPHYSLAB Environmental Physics Laboratory, Universidade de Vigo, Ourense, Spain.
School of Mechanical, Aerospace and Civil Engineering, University of Manchester, Manchester, U.K.

This file is part of DualSPHysics. 

DualSPHysics is free software: you can redistribute it and/or modify it under the terms of the GNU Lesser General Public License 
as published by the Free Software Foundation; either version 2.1 of the License, or (at your option) any later version.

DualSPHysics is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public License for more details. 

You should have received a copy of the GNU Lesser General Public License along with DualSPHysics. If not, see <http://www.gnu.org/licenses/>. 
*/

/// \file JSphGpu_ker.cu \brief Implements functions and CUDA kernels for the Particle Interaction and System Update.

#include "JSphGpu_ker.h"
#include "JBlockSizeAuto.h"
#include "JLog2.h"
#include <cfloat>
#include <math_constants.h>
//#include "JDgKerPrint.h"
//#include "JDgKerPrint_ker.h"

#pragma warning(disable : 4267) //Cancels "warning C4267: conversion from 'size_t' to 'int', possible loss of data"
#pragma warning(disable : 4244) //Cancels "warning C4244: conversion from 'unsigned __int64' to 'unsigned int', possible loss of data"
#pragma warning(disable : 4503) //Cancels "warning C4503: decorated name length exceeded, name was truncated"
#include <cuda_runtime.h>
#include <thrust/device_vector.h>
#include <thrust/sort.h>

__constant__ StCteInteraction CTE;

namespace cusph{

//==============================================================================
/// Comprueba error y finaliza ejecucion.
/// Checks error and ends execution.
//==============================================================================
#define CheckErrorCuda(text)  __CheckErrorCuda(text,__FILE__,__LINE__)
void __CheckErrorCuda(const char *text,const char *file,const int line){
  cudaError_t err=cudaGetLastError();
  if(cudaSuccess!=err){
    char cad[2048]; 
    sprintf(cad,"%s (CUDA error: %s -> %s:%i).\n",text,cudaGetErrorString(err),file,line); 
    throw std::string(cad);
  }
}

//==============================================================================
/// Devuelve tama�o de gridsize segun parametros.
/// Returns size of gridsize according to parameters.
//==============================================================================
dim3 GetGridSize(unsigned n,unsigned blocksize){
  dim3 sgrid;//=dim3(1,2,3);
  unsigned nb=unsigned(n+blocksize-1)/blocksize;//-Numero total de bloques a lanzar. //-Total block number to throw.
  sgrid.x=(nb<=65535? nb: unsigned(sqrt(float(nb))));
  sgrid.y=(nb<=65535? 1: unsigned((nb+sgrid.x-1)/sgrid.x));
  sgrid.z=1;
  return(sgrid);
}

//==============================================================================
/// Reduccion mediante maximo de valores float en memoria shared para un warp.
/// Reduction using maximum of float values in shared memory for a warp.
//==============================================================================
template <unsigned blockSize> __device__ void KerReduMaxFloatWarp(volatile float* sdat,unsigned tid) {
  if(blockSize>=64)sdat[tid]=max(sdat[tid],sdat[tid+32]);
  if(blockSize>=32)sdat[tid]=max(sdat[tid],sdat[tid+16]);
  if(blockSize>=16)sdat[tid]=max(sdat[tid],sdat[tid+8]);
  if(blockSize>=8)sdat[tid]=max(sdat[tid],sdat[tid+4]);
  if(blockSize>=4)sdat[tid]=max(sdat[tid],sdat[tid+2]);
  if(blockSize>=2)sdat[tid]=max(sdat[tid],sdat[tid+1]);
}

//==============================================================================
/// Acumula la suma de n valores del vector dat[], guardando el resultado al 
/// principio de res[] (Se usan tantas posiciones del res[] como bloques, 
/// quedando el resultado final en res[0]).
/// Accumulates the sum of n values of array dat[], storing the result in 
/// the beginning of res[].(Many positions of res[] are used as blocks, 
/// storing the final result in res[0]).
//==============================================================================
template <unsigned blockSize> __global__ void KerReduMaxFloat(unsigned n,unsigned ini,const float *dat,float *res){
  extern __shared__ float sdat[];
  unsigned tid=threadIdx.x;
  unsigned c=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x;
  sdat[tid]=(c<n? dat[c+ini]: -FLT_MAX);
  __syncthreads();
  if(blockSize>=512){ if(tid<256)sdat[tid]=max(sdat[tid],sdat[tid+256]);  __syncthreads(); }
  if(blockSize>=256){ if(tid<128)sdat[tid]=max(sdat[tid],sdat[tid+128]);  __syncthreads(); }
  if(blockSize>=128){ if(tid<64) sdat[tid]=max(sdat[tid],sdat[tid+64]);   __syncthreads(); }
  if(tid<32)KerReduMaxFloatWarp<blockSize>(sdat,tid);
  if(tid==0)res[blockIdx.y*gridDim.x + blockIdx.x]=sdat[0];
}

//==============================================================================
/// Devuelve el maximo de un vector, usando resu[] como vector auxiliar. El tama�o
/// de resu[] debe ser >= a (N/SPHBSIZE+1)+(N/(SPHBSIZE*SPHBSIZE)+SPHBSIZE)
/// Returns the maximum of an array, using resu[] as auxiliar array.
/// Size of resu[] must be >= a (N/SPHBSIZE+1)+(N/(SPHBSIZE*SPHBSIZE)+SPHBSIZE)
//==============================================================================
float ReduMaxFloat(unsigned ndata,unsigned inidata,float* data,float* resu){
  float resf;
  if(1){
    unsigned n=ndata,ini=inidata;
    unsigned smemSize=SPHBSIZE*sizeof(float);
    dim3 sgrid=GetGridSize(n,SPHBSIZE);
    unsigned n_blocks=sgrid.x*sgrid.y;
    float *dat=data;
    float *resu1=resu,*resu2=resu+n_blocks;
    float *res=resu1;
    while(n>1){
      KerReduMaxFloat<SPHBSIZE><<<sgrid,SPHBSIZE,smemSize>>>(n,ini,dat,res);
      n=n_blocks; ini=0;
      sgrid=GetGridSize(n,SPHBSIZE);  
      n_blocks=sgrid.x*sgrid.y;
      if(n>1){
        dat=res; res=(dat==resu1? resu2: resu1); 
      }
    }
    if(ndata>1)cudaMemcpy(&resf,res,sizeof(float),cudaMemcpyDeviceToHost);
    else cudaMemcpy(&resf,data,sizeof(float),cudaMemcpyDeviceToHost);
  }
  //else{//-Using Thrust library is slower than ReduMasFloat() with ndata < 5M.
  //  thrust::device_ptr<float> dev_ptr(data);
  //  resf=thrust::reduce(dev_ptr,dev_ptr+ndata,-FLT_MAX,thrust::maximum<float>());
  //}
  return(resf);
}

//==============================================================================
/// Acumula la suma de n valores del vector dat[].w, guardando el resultado al 
/// principio de res[] (Se usan tantas posiciones del res[] como bloques, 
/// quedando el resultado final en res[0]).
/// Accumulates the sum of n values of array dat[], storing the result in 
/// the beginning of res[].(Many positions of res[] are used as blocks, 
/// storing the final result in res[0]).
//==============================================================================
template <unsigned blockSize> __global__ void KerReduMaxFloat_w(unsigned n,unsigned ini,const float4 *dat,float *res){
  extern __shared__ float sdat[];
  unsigned tid=threadIdx.x;
  unsigned c=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x;
  sdat[tid]=(c<n? dat[c+ini].w: -FLT_MAX);
  __syncthreads();
  if(blockSize>=512){ if(tid<256)sdat[tid]=max(sdat[tid],sdat[tid+256]);  __syncthreads(); }
  if(blockSize>=256){ if(tid<128)sdat[tid]=max(sdat[tid],sdat[tid+128]);  __syncthreads(); }
  if(blockSize>=128){ if(tid<64) sdat[tid]=max(sdat[tid],sdat[tid+64]);   __syncthreads(); }
  if(tid<32)KerReduMaxFloatWarp<blockSize>(sdat,tid);
  if(tid==0)res[blockIdx.y*gridDim.x + blockIdx.x]=sdat[0];
}

//==============================================================================
/// Devuelve el maximo de la componente w de un vector float4, usando resu[] como 
/// vector auxiliar. El tama�o de resu[] debe ser >= a (N/SPHBSIZE+1)+(N/(SPHBSIZE*SPHBSIZE)+SPHBSIZE)
/// Returns the maximum of an array, using resu[] as auxiliar array.
/// Size of resu[] must be >= a (N/SPHBSIZE+1)+(N/(SPHBSIZE*SPHBSIZE)+SPHBSIZE)
//==============================================================================
float ReduMaxFloat_w(unsigned ndata,unsigned inidata,float4* data,float* resu){
  unsigned n=ndata,ini=inidata;
  unsigned smemSize=SPHBSIZE*sizeof(float);
  dim3 sgrid=GetGridSize(n,SPHBSIZE);
  unsigned n_blocks=sgrid.x*sgrid.y;
  float *dat=NULL;
  float *resu1=resu,*resu2=resu+n_blocks;
  float *res=resu1;
  while(n>1){
    if(!dat)KerReduMaxFloat_w<SPHBSIZE><<<sgrid,SPHBSIZE,smemSize>>>(n,ini,data,res);
    else KerReduMaxFloat<SPHBSIZE><<<sgrid,SPHBSIZE,smemSize>>>(n,ini,dat,res);
    n=n_blocks; ini=0;
    sgrid=GetGridSize(n,SPHBSIZE);  
    n_blocks=sgrid.x*sgrid.y;
    if(n>1){
      dat=res; res=(dat==resu1? resu2: resu1); 
    }
  }
  float resf;
  if(ndata>1)cudaMemcpy(&resf,res,sizeof(float),cudaMemcpyDeviceToHost);
  else{
    float4 resf4;
    cudaMemcpy(&resf4,data,sizeof(float4),cudaMemcpyDeviceToHost);
    resf=resf4.w;
  }
  return(resf);
}

//==============================================================================
/// Graba constantes para la interaccion a la GPU.
/// Stores constants for the GPU interaction.
//==============================================================================
void CteInteractionUp(const StCteInteraction *cte){
  cudaMemcpyToSymbol(CTE,cte,sizeof(StCteInteraction));
}

//------------------------------------------------------------------------------
/// Inicializa array con el valor indicado.
/// Initialises array with the indicated value.
//------------------------------------------------------------------------------
__global__ void KerInitArray(unsigned n,float3 *v,float3 value)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la particula //-NI of the particle
  if(p<n)v[p]=value;
}

//==============================================================================
/// Inicializa array con el valor indicado.
/// Initialises array with the indicated value.
//==============================================================================
void InitArray(unsigned n,float3 *v,tfloat3 value){
  if(n){
    dim3 sgrid=GetGridSize(n,SPHBSIZE);
    KerInitArray <<<sgrid,SPHBSIZE>>> (n,v,Float3(value));
  }
}

//------------------------------------------------------------------------------
/// Pone v[].y a cero.
/// Sets v[].y to zero.
//------------------------------------------------------------------------------
__global__ void KerResety(unsigned n,unsigned ini,float3 *v)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle
  if(p<n)v[p+ini].y=0;
}

//==============================================================================
/// Pone v[].y a cero.
/// Sets v[].y to zero.
//==============================================================================
void Resety(unsigned n,unsigned ini,float3 *v){
  if(n){
    dim3 sgrid=GetGridSize(n,SPHBSIZE);
    KerResety <<<sgrid,SPHBSIZE>>> (n,ini,v);
  }
}

//------------------------------------------------------------------------------
/// Calculates module^2 of ace.
//------------------------------------------------------------------------------
__global__ void KerComputeAceMod(unsigned n,const float3 *ace,float *acemod)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(p<n){
    const float3 r=ace[p];
    acemod[p]=r.x*r.x+r.y*r.y+r.z*r.z;
  }
}

//==============================================================================
/// Calculates module^2 of ace.
//==============================================================================
void ComputeAceMod(unsigned n,const float3 *ace,float *acemod){
  if(n){
    dim3 sgrid=GetGridSize(n,SPHBSIZE);
    KerComputeAceMod <<<sgrid,SPHBSIZE>>> (n,ace,acemod);
  }
}

//------------------------------------------------------------------------------
/// Calculates module^2 of ace, comprobando que la particula sea normal.
//------------------------------------------------------------------------------
__global__ void KerComputeAceMod(unsigned n,const word *code,const float3 *ace,float *acemod)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(p<n){
    const float3 r=(CODE_GetSpecialValue(code[p])==CODE_NORMAL? ace[p]: make_float3(0,0,0));
    acemod[p]=r.x*r.x+r.y*r.y+r.z*r.z;
  }
}

//==============================================================================
/// Calculates module^2 of ace, comprobando que la particula sea normal.
//==============================================================================
void ComputeAceMod(unsigned n,const word *code,const float3 *ace,float *acemod){
  if(n){
    dim3 sgrid=GetGridSize(n,SPHBSIZE);
    KerComputeAceMod <<<sgrid,SPHBSIZE>>> (n,code,ace,acemod);
  }
}

//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Calculates module of rhop. -��//MP
//------------------------------------------------------------------------------
__global__ void KerComputeRhopModMP(unsigned n,const float4 *velrhop,float *rhopmod)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(p<n){
    const float r=velrhop[p].w;
    rhopmod[p]=r;
  }
}

//==============================================================================
/// Calculates module of rhop. -��//MP
//==============================================================================
void ComputeRhopModMP(unsigned n,const float4 *velrhop,float *rhopmod){
  if(n){
    dim3 sgrid=GetGridSize(n,SPHBSIZE);
    KerComputeRhopModMP <<<sgrid,SPHBSIZE>>> (n,velrhop,rhopmod);
  }
}

//------------------------------------------------------------------------------
/// Calculates module of rhop, provided the particle is normal. -��//MP
//------------------------------------------------------------------------------
__global__ void KerComputeRhopModMP(unsigned n,const word *code,const float4 *velrhop,float *rhopmod)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(p<n){
    const float r=(CODE_GetSpecialValue(code[p])==CODE_NORMAL? velrhop[p].w: 0);
    rhopmod[p]=r;
  }
}

//==============================================================================
/// Calculates module of rhop, provided the particle is normal. -��//MP
//==============================================================================
void ComputeRhopModMP(unsigned n,const word *code,const float4 *velrhop,float *rhopmod){
  if(n){
    dim3 sgrid=GetGridSize(n,SPHBSIZE);
    KerComputeRhopModMP <<<sgrid,SPHBSIZE>>> (n,code,velrhop,rhopmod);
  }
}
//�����������������������������������������������������������������������//MP

//##############################################################################
//# Otros kernels...
//# Other kernels...
//##############################################################################
//------------------------------------------------------------------------------
/// Calculates module^2 of vel.
//------------------------------------------------------------------------------
__global__ void KerComputeVelMod(unsigned n,const float4 *vel,float *velmod)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(p<n){
    const float4 r=vel[p];
    velmod[p]=r.x*r.x+r.y*r.y+r.z*r.z;
  }
}

//==============================================================================
/// Calculates module^2 of vel.
//==============================================================================
void ComputeVelMod(unsigned n,const float4 *vel,float *velmod){
  if(n){
    dim3 sgrid=GetGridSize(n,SPHBSIZE);
    KerComputeVelMod <<<sgrid,SPHBSIZE>>> (n,vel,velmod);
  }
}


//##############################################################################
//# Kernels para preparar calculo de fuerzas con Pos-Simple.
//# Kernels for preparing force computation with Pos-Simple.
//##############################################################################
//------------------------------------------------------------------------------
/// Prepara variables para interaccion pos-simple.
/// Prepare variables for pos-simple interaction.
//------------------------------------------------------------------------------
__global__ void KerPreInteractionSimple(unsigned n,const double2 *posxy,const double *posz
  ,const float4 *velrhop,float4 *pospress,float cteb,float gamma)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula
  if(p<n){
    //Calcular press en simple o doble precision no parece tener ningun efecto positivo significativo,
    //y como para PosDouble si se calcula antes y se lee en la interaccion supondria una perdida de 
    //rendimiento del 6% o 15% (gtx480 o k20c) mejor se calcula en simple siempre.
    //Computes press in single or double precision,although the latter does not have any significant positive effect,
    //and like PosDouble if it is previously calculated and read the interaction can incur losses of
    //performance of 6% or 15% (GTX480 or k20c) so it is best calculated as always simple.
    const float rrhop=velrhop[p].w;
    float press=cteb*(powf(rrhop*CTE.ovrhopzero,gamma)-1.0f);
    double2 rpos=posxy[p];
    pospress[p]=make_float4(float(rpos.x),float(rpos.y),float(posz[p]),press);
  }
}

//==============================================================================
/// Prepara variables para interaccion pos-simple.
/// Prepare variables for pos-simple interaction.
//==============================================================================
void PreInteractionSimple(unsigned np,const double2 *posxy,const double *posz
  ,const float4 *velrhop,float4 *pospress,float cteb,float ctegamma)
{
  if(np){
    dim3 sgrid=GetGridSize(np,SPHBSIZE);
    KerPreInteractionSimple <<<sgrid,SPHBSIZE>>> (np,posxy,posz,velrhop,pospress,cteb,ctegamma);
  }
}
//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Prepare variables for pos-simple interaction for multiphase flows. -��//MP
//------------------------------------------------------------------------------
__global__ void KerPreInteractionSimpleMP(unsigned n,const double2 *posxy,const double *posz
  ,const float4 *velrhop,float4 *pospress,word *code,StPhaseData *phasedata)
{
	extern volatile __shared__ StPhasePresData presdata[]; //Find material properties for computing pressure
    if(threadIdx.x==0){ //only executed by thread 0
	  for(unsigned i=0; i<CTE.phasecount; i++){
		  presdata[i].MkValue=phasedata[i].MkValue;
		  presdata[i].PhaseRhop0=phasedata[i].PhaseRhop0;
		  presdata[i].PhaseGamma=phasedata[i].PhaseGamma;
		  presdata[i].PhaseCs0=phasedata[i].PhaseCs0;
		  presdata[i].PhaseType=phasedata[i].PhaseType;
	  }
  }
  __syncthreads();
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula
  if(p<n){
    //Calcular press en simple o doble precision no parece tener ningun efecto positivo significativo,
    //y como para PosDouble si se calcula antes y se lee en la interaccion supondria una perdida de 
    //rendimiento del 6% o 15% (gtx480 o k20c) mejor se calcula en simple siempre.
    //Computes press in single or double precision,although the latter does not have any significant positive effect,
    //and like PosDouble if it is previously calculated and read the interaction can incur losses of
    //performance of 6% or 15% (GTX480 or k20c) so it is best calculated as always simple.
	float rhop0; float cs0; float gamma; unsigned phasetype;
	for(unsigned ipres=0; ipres<CTE.phasecount; ipres++){
		if(CODE_GetTypeAndValue(code[p])==presdata[ipres].MkValue){
			rhop0=presdata[ipres].PhaseRhop0;
			cs0=presdata[ipres].PhaseCs0;
			gamma=presdata[ipres].PhaseGamma;
			phasetype=presdata[ipres].PhaseType;
			break;
		}
	}
	const float rrhop=velrhop[p].w;
	const float cteb=cs0*cs0*rhop0/gamma;
	float press=cteb*(powf(rrhop/rhop0,gamma)-1.0f);
	if(phasetype==1){ //Add cohesion term for gases
		press-=CTE.mpcoef*rrhop*rrhop/rhop0;
	}
	double2 rpos=posxy[p];
	pospress[p]=make_float4(float(rpos.x),float(rpos.y),float(posz[p]),press);
  }
}
//�����������������������������������������������������������������������//MP

//�����������������������������������������������������������������������//MP
//==============================================================================
/// Prepare variables for pos-simple interaction for multiphase flows. -��//MP
//==============================================================================
void PreInteractionSimpleMP(unsigned np,const double2 *posxy,const double *posz
  ,const float4 *velrhop,float4 *pospress,word *code,StPhaseData *phasedata,unsigned phasecount)
{
  if(np){
    dim3 sgrid=GetGridSize(np,SPHBSIZE);
    KerPreInteractionSimpleMP <<<sgrid,SPHBSIZE,phasecount*sizeof(StPhasePresData)>>> (np,posxy,posz,velrhop,pospress,code,phasedata);
  }
}
//�����������������������������������������������������������������������//MP


//##############################################################################
//# Kernels auxiliares para interaccion.
//# Auxiliary kernels for the interaction.
//##############################################################################
//------------------------------------------------------------------------------
/// Devuelve posicion, vel, rhop y press de particula. USADA
/// Returns position, vel, rhop and press of a particle. USED
//------------------------------------------------------------------------------
template<bool psimple> __device__ void KerGetParticleData(unsigned p1
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop
  ,float3 &velp1,float &rhopp1,double3 &posdp1,float3 &posp1,float &pressp1)
{
  float4 r=velrhop[p1];
  velp1=make_float3(r.x,r.y,r.z);
  rhopp1=r.w;
  if(psimple){
    float4 pxy=pospress[p1];
    posp1=make_float3(pxy.x,pxy.y,pxy.z);
    pressp1=pxy.w;
  }
  else{
    double2 pxy=posxy[p1];
    posdp1=make_double3(pxy.x,pxy.y,posz[p1]);
    pressp1=(CTE.cteb*(powf(rhopp1*CTE.ovrhopzero,CTE.gamma)-1.0f));
  }
}

//------------------------------------------------------------------------------
/// Devuelve posicion y vel de particula.
/// Returns postion and vel of a particle.
//------------------------------------------------------------------------------
template<bool psimple> __device__ void KerGetParticleData(unsigned p1
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop
  ,float3 &velp1,double3 &posdp1,float3 &posp1)
{
  float4 r=velrhop[p1];
  velp1=make_float3(r.x,r.y,r.z);
  if(psimple){
    float4 pxy=pospress[p1];
    posp1=make_float3(pxy.x,pxy.y,pxy.z);
  }
  else{
    double2 pxy=posxy[p1];
    posdp1=make_double3(pxy.x,pxy.y,posz[p1]);
  }
}

//------------------------------------------------------------------------------
/// Devuelve posicion de particula. USADA
/// Returns particle postion. USED
//------------------------------------------------------------------------------
template<bool psimple> __device__ void KerGetParticleData(unsigned p1
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,double3 &posdp1,float3 &posp1)
{
  if(psimple){
    float4 pxy=pospress[p1];
    posp1=make_float3(pxy.x,pxy.y,pxy.z);
  }
  else{
    double2 pxy=posxy[p1];
    posdp1=make_double3(pxy.x,pxy.y,posz[p1]);
  }
}

//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Devuelve posicion, vel, rhop y press de particula. USADA
/// Returns position, vel, rhop and press of a particle. USED -��//MP
//------------------------------------------------------------------------------
template<bool psimple> __device__ void KerGetParticleDataMP(unsigned p1
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop
  ,float3 &velp1,float &rhopp1,double3 &posdp1,float3 &posp1,float &pressp1
  ,const float rhop0,const float cs0,const float gamma,const unsigned phasetype)
{
  float4 r=velrhop[p1];
  velp1=make_float3(r.x,r.y,r.z);
  rhopp1=r.w;
  if(psimple){
    float4 pxy=pospress[p1];
    posp1=make_float3(pxy.x,pxy.y,pxy.z);
    pressp1=pxy.w;
  }
  else{
    double2 pxy=posxy[p1];
    posdp1=make_double3(pxy.x,pxy.y,posz[p1]);
	float b=cs0*cs0*rhop0/gamma;
    pressp1=(b*(powf(rhopp1/rhop0,gamma)-1.0f));
	if(phasetype==1)pressp1-=CTE.mpcoef/rhop0*rhopp1*rhopp1; //Add cohesion term for gases
  }
}
//�����������������������������������������������������������������������//MP

//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Devuelve posicion, vel, rhop y press de particula. USADA
/// Returns position, vel, rhop and press of a particle. USED -��//MP
//------------------------------------------------------------------------------
template<bool psimple> __device__ void KerGetParticleDataMP(unsigned p1
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop
  ,float3 &velp1,float &rhopp1,double3 &posdp1,float3 &posp1)
{
  float4 r=velrhop[p1];
  velp1=make_float3(r.x,r.y,r.z);
  rhopp1=r.w;
  if(psimple){
    float4 pxy=pospress[p1];
    posp1=make_float3(pxy.x,pxy.y,pxy.z);
  }
  else{
    double2 pxy=posxy[p1];
    posdp1=make_double3(pxy.x,pxy.y,posz[p1]);
  }
}
//�����������������������������������������������������������������������//MP

//------------------------------------------------------------------------------
/// Devuelve drx, dry y drz entre dos particulas. USADA
/// Returns drx, dry and drz between the particles. USED
//------------------------------------------------------------------------------
template<bool psimple> __device__ void KerGetParticlesDr(int p2
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,const double3 &posdp1,const float3 &posp1
  ,float &drx,float &dry,float &drz,float &pressp2)
{
  if(psimple){
    float4 posp2=pospress[p2];
    drx=posp1.x-posp2.x;
    dry=posp1.y-posp2.y;
    drz=posp1.z-posp2.z;
    pressp2=posp2.w;
  }
  else{
    double2 posp2=posxy[p2];
    drx=float(posdp1.x-posp2.x);
    dry=float(posdp1.y-posp2.y);
    drz=float(posdp1.z-posz[p2]);
    pressp2=0;
  }
}

//------------------------------------------------------------------------------
/// Devuelve drx, dry y drz entre dos particulas.
/// Returns drx, dry and drz between the particles.
//------------------------------------------------------------------------------
template<bool psimple> __device__ void KerGetParticlesDr(int p2
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,const double3 &posdp1,const float3 &posp1
  ,float &drx,float &dry,float &drz)
{
  if(psimple){
    float4 posp2=pospress[p2];
    drx=posp1.x-posp2.x;
    dry=posp1.y-posp2.y;
    drz=posp1.z-posp2.z;
  }
  else{
    double2 posp2=posxy[p2];
    drx=float(posdp1.x-posp2.x);
    dry=float(posdp1.y-posp2.y);
    drz=float(posdp1.z-posz[p2]);
  }
}

//------------------------------------------------------------------------------
/// Devuelve limites de celdas para interaccion.
/// Returns cell limits for the interaction.
//------------------------------------------------------------------------------
__device__ void KerGetInteractionCells(unsigned rcell
  ,int hdiv,const uint4 &nc,const int3 &cellzero
  ,int &cxini,int &cxfin,int &yini,int &yfin,int &zini,int &zfin)
{
  //-Obtiene limites de interaccion
  //-Obtains interaction limits.
  const int cx=PC__Cellx(CTE.cellcode,rcell)-cellzero.x;
  const int cy=PC__Celly(CTE.cellcode,rcell)-cellzero.y;
  const int cz=PC__Cellz(CTE.cellcode,rcell)-cellzero.z;
  //-Codigo para hdiv 1 o 2 pero no cero.
  //-Code for hdiv 1 or 2 but not zero.
  cxini=cx-min(cx,hdiv);
  cxfin=cx+min(nc.x-cx-1,hdiv)+1;
  yini=cy-min(cy,hdiv);
  yfin=cy+min(nc.y-cy-1,hdiv)+1;
  zini=cz-min(cz,hdiv);
  zfin=cz+min(nc.z-cz-1,hdiv)+1;
}

//------------------------------------------------------------------------------
/// Devuelve limites de celdas para interaccion.
/// Returns cell limits for the interaction.
//------------------------------------------------------------------------------
__device__ void KerGetInteractionCells(double px,double py,double pz
  ,int hdiv,const uint4 &nc,const int3 &cellzero
  ,int &cxini,int &cxfin,int &yini,int &yfin,int &zini,int &zfin)
{
  //-Obtiene limites de interaccion
  //-Obtains interaction limits.
  const int cx=int((px-CTE.domposminx)/CTE.scell)-cellzero.x;
  const int cy=int((py-CTE.domposminy)/CTE.scell)-cellzero.y;
  const int cz=int((pz-CTE.domposminz)/CTE.scell)-cellzero.z;
  //-Codigo para hdiv 1 o 2 pero no cero.
  //-Code for hdiv 1 or 2 but not zero.
  cxini=cx-min(cx,hdiv);
  cxfin=cx+min(nc.x-cx-1,hdiv)+1;
  yini=cy-min(cy,hdiv);
  yfin=cy+min(nc.y-cy-1,hdiv)+1;
  zini=cz-min(cz,hdiv);
  zfin=cz+min(nc.z-cz-1,hdiv)+1;
}

//------------------------------------------------------------------------------
/// Devuelve valores de kernel: frx, fry y frz.
/// Returns kernel values: frx, fry and frz.
//------------------------------------------------------------------------------
__device__ void KerGetKernel(float rr2,float drx,float dry,float drz
  ,float &frx,float &fry,float &frz)
{
  const float rad=sqrt(rr2);
  const float qq=rad/CTE.h;
  //-Wendland kernel.
  const float wqq1=1.f-0.5f*qq;
  const float fac=CTE.bwen*qq*wqq1*wqq1*wqq1/rad;
  frx=fac*drx; fry=fac*dry; frz=fac*drz;
}

//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Returns Wendland kernel and kernel gradient values: wab, frx, fry and frz. -��//MP
//------------------------------------------------------------------------------
__device__ void KerGetKernelShift(float rr2,float drx,float dry,float drz
  ,float &frx,float &fry,float &frz,float &wab)
{
  const float rad=sqrt(rr2);
  const float qq=rad/CTE.h;
  //-Wendland kernel.
  const float wqq1=1.f-0.5f*qq;
  const float fac=CTE.bwen*qq*wqq1*wqq1*wqq1/rad;
  frx=fac*drx; fry=fac*dry; frz=fac*drz;
  wab=CTE.awen*(2.f*qq+1.f)*wqq1*wqq1*wqq1*wqq1;
}
//�����������������������������������������������������������������������//MP

//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Returns tensile instability correction (Monaghan) for particle shifting for Wendland kernel. -��//MP
//------------------------------------------------------------------------------
__device__ void KerGetTensWendland(float wab,float &tens)
{
  float coefr=0.2f;
  const float rad=float(sqrt(CTE.dp));
  const float qq=rad/CTE.h;
  const float wqq1=1.f-0.5f*qq;
  const float wqq2=wqq1*wqq1;
  float wabti=CTE.awen*(2.f*qq+1.f)*wqq2*wqq2;
  float wab1=(wab/wabti)*(wab/wabti);
  tens=coefr*wab1*wab1;
}
//�����������������������������������������������������������������������//MP

//------------------------------------------------------------------------------
/// Devuelve valores de kernel Cubic sin correccion tensil, gradients: frx, fry y frz.
/// Return values of kernel Cubic without tensil correction, gradients: frx, fry and frz.
//------------------------------------------------------------------------------
__device__ void KerGetKernelCubic(float rr2,float drx,float dry,float drz
  ,float &frx,float &fry,float &frz)
{
  const float rad=sqrt(rr2);
  const float qq=rad/CTE.h;
  //-Cubic Spline kernel
  float fac;
  if(rad>CTE.h){
    float wqq1=2.0f-qq;
    float wqq2=wqq1*wqq1;
    fac=CTE.cubic_c2*wqq2/rad;
  }
  else{
    float wqq2=qq*qq;
    fac=(CTE.cubic_c1*qq+CTE.cubic_d1*wqq2)/rad;
  }
  //-Gradients.
  frx=fac*drx; fry=fac*dry; frz=fac*drz;
}

//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Return values of Cubic kernel and gradients without tensil correction: wab, frx, fry and frz. -��//MP
//------------------------------------------------------------------------------
__device__ void KerGetKernelCubicShift(float rr2,float drx,float dry,float drz
  ,float &frx,float &fry,float &frz,float &wab)
{
  const float rad=sqrt(rr2);
  const float qq=rad/CTE.h;
  //-Cubic Spline kernel
  float fac;
  if(rad>CTE.h){
    float wqq1=2.0f-qq;
    float wqq2=wqq1*wqq1;
    fac=CTE.cubic_c2*wqq2/rad;
	wab=CTE.cubic_a24*(wqq2*wqq1);
  }
  else{
    float wqq2=qq*qq;
    fac=(CTE.cubic_c1*qq+CTE.cubic_d1*wqq2)/rad;
    wab=CTE.cubic_a2*(1.0f-1.5f*wqq2+0.75f*wqq2*qq);
  }
  //-Gradients.
  frx=fac*drx; fry=fac*dry; frz=fac*drz;
}
//�����������������������������������������������������������������������//MP

//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Returns tensile instability correction (Monaghan) for particle shifting for Cubic kernel. -��//MP
//------------------------------------------------------------------------------
__device__ void KerGetTensCubic(float wab,float &tens)
{
  float coefr=0.2f;
  const float rad=float(sqrt(CTE.dp));
  const float qq=rad/CTE.h;
  float wabti;
  //-Cubic Spline kernel
  if(rad>CTE.h){
    float wqq1=2.0f-qq;
    float wqq2=wqq1*wqq1;
	wabti=CTE.cubic_a24*(wqq2*wqq1);
  }
  else{
    float wqq2=qq*qq;
	wabti=CTE.cubic_a2*(1.0f-1.5f*wqq2+0.75f*wqq2*qq);
  }
  float wab1=(wab/wabti)*(wab/wabti);
  tens=coefr*wab1*wab1;
}
//�����������������������������������������������������������������������//MP

//------------------------------------------------------------------------------
/// Devuelve correccion tensil para kernel Cubic.
/// Return tensil correction for kernel Cubic.
/// Altered to correspond to new discretisation of the momentum equation -��//MP
//------------------------------------------------------------------------------
__device__ float KerGetKernelCubicTensil(float rr2
  ,float rhopp1,float pressp1,float rhopp2,float pressp2)
{
  const float rad=sqrt(rr2);
  const float qq=rad/CTE.h;
  //-Cubic Spline kernel
  float wab;
  if(rad>CTE.h){
    float wqq1=2.0f-qq;
    float wqq2=wqq1*wqq1;
    wab=CTE.cubic_a24*(wqq2*wqq1);
  }
  else{
    float wqq2=qq*qq;
    float wqq3=wqq2*qq;
    wab=CTE.cubic_a2*(1.0f-1.5f*wqq2+0.75f*wqq3);
  }
  //-Tensile correction.
  float fab=wab*CTE.cubic_odwdeltap;
  fab*=fab; fab*=fab; //fab=fab^4
//�����������������������������������������������������������������������//MP
  const float tensilp1=(pressp1/(rhopp1*rhopp2))*(pressp1>0? 0.01f: -0.2f);
  const float tensilp2=(pressp2/(rhopp1*rhopp2))*(pressp2>0? 0.01f: -0.2f);
//�����������������������������������������������������������������������//MP
  return(fab*(tensilp1+tensilp2));
}

//�����������������������������������������������������������������������//MP
//==============================================================================
///Restrict shifting on the free surface -��//MP
//==============================================================================
__device__ void KerShiftingFreeSurfaceMP(bool sim2d,const float3 concgr,float3 &congr)
{
	float3 norm=make_float3(concgr.x,concgr.y,concgr.z);
	float3 tang=make_float3(0,0,0);
	float3 bitang=make_float3(0,0,0);

	//-tangent and bitangent calculation
	tang.x=norm.z+norm.y;		
	if(!sim2d)tang.y=-(norm.x+norm.z);	
	tang.z=-norm.x+norm.y;
	bitang.x=tang.y*norm.z-norm.y*tang.z;
	if(!sim2d)bitang.y=norm.x*tang.z-tang.x*norm.z;
	bitang.z=tang.x*norm.y-norm.x*tang.y;

	//-unit normal vector
	float temp=norm.x*norm.x+norm.y*norm.y+norm.z*norm.z;
	temp=sqrt(temp);
	norm.x=norm.x/temp; norm.y=norm.y/temp; norm.z=norm.z/temp;
	if(!temp){norm.x=0.f; norm.y=0.f; norm.z=0.f;}

	//-unit tangent vector
	temp=tang.x*tang.x+tang.y*tang.y+tang.z*tang.z;
	temp=sqrt(temp);
	tang.x=tang.x/temp; tang.y=tang.y/temp; tang.z=tang.z/temp;
	if(!temp){tang.x=0.f; tang.y=0.f; tang.z=0.f;}

	//-unit bitangent vector
	temp=bitang.x*bitang.x+bitang.y*bitang.y+bitang.z*bitang.z;
	temp=sqrt(temp);
	bitang.x=bitang.x/temp; bitang.y=bitang.y/temp; bitang.z=bitang.z/temp;
	if(!temp){bitang.x=0.f; bitang.y=0.f; bitang.z=0.f;}

	//-gradient calculation
	float dcds=tang.x*concgr.x+tang.z*concgr.z+tang.y*concgr.y;
	float dcdn=norm.x*concgr.x+norm.z*concgr.z+norm.y*concgr.y;
	float dcdb=bitang.x*concgr.x+bitang.z*concgr.z+bitang.y*concgr.y;

	//-free surface correction
	congr.x=dcds*tang.x+dcdb*bitang.x;
	congr.y=dcds*tang.y+dcdb*bitang.y;
	congr.z=dcds*tang.z+dcdb*bitang.z;
	if( CTE.shiftgrad.x || CTE.shiftgrad.y || CTE.shiftgrad.z){
		congr.x+=0.1*(dcdn*norm.x-CTE.shiftgrad.x)*norm.x;
		congr.y+=0.1*(dcdn*norm.y-CTE.shiftgrad.y)*norm.y;
		congr.z+=0.1*(dcdn*norm.z-CTE.shiftgrad.z)*norm.z;
	}
}
//�����������������������������������������������������������������������//MP

//##############################################################################
//# Kernels para calculo de fuerzas (Pos-Double)
//# Kernels for calculating forces (Pos-Double)
//##############################################################################
//------------------------------------------------------------------------------
/// Realiza la interaccion de una particula con un conjunto de ellas. Bound-Fluid/Float
/// Interaction of a particle with a set of particles (Bound-Fluid).
//------------------------------------------------------------------------------
template<bool psimple,TpKernel tker,TpFtMode ftmode> __device__ void KerInteractionForcesBoundBox
  (unsigned p1,const unsigned &pini,const unsigned &pfin
  ,const float *ftomassp
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop,const word *code,const unsigned* idp
  ,float massf,double3 posdp1,float3 posp1,float3 velp1,float &arp1,float &visc)
{
  for(int p2=pini;p2<pfin;p2++){
    float drx,dry,drz;
    KerGetParticlesDr<psimple>(p2,posxy,posz,pospress,posdp1,posp1,drx,dry,drz);
    float rr2=drx*drx+dry*dry+drz*drz;
    if(rr2<=CTE.fourh2 && rr2>=ALMOSTZERO){
      //-Wendland or Cubic Spline kernel.
      float frx,fry,frz;
      if(tker==KERNEL_Wendland)KerGetKernel(rr2,drx,dry,drz,frx,fry,frz);
      else if(tker==KERNEL_Cubic)KerGetKernelCubic(rr2,drx,dry,drz,frx,fry,frz);

      const float4 velrhop2=velrhop[p2];
      //-Obtiene masa de particula p2 en caso de existir floatings.
      //-Obtains particle mass p2 if there are floating bodies.
      float ftmassp2;    //-Contiene masa de particula floating o massf si es fluid. //-Contains mass of floating body or massf if fluid.
      bool compute=true; //-Se desactiva cuando se usa DEM y es float-float o float-bound. //-Deactivated when DEM is used and is float-float or float-bound.
      if(USE_FLOATING){
        const word cod=code[p2];
        bool ftp2=(CODE_GetType(cod)==CODE_TYPE_FLOATING);
        ftmassp2=(ftp2? ftomassp[CODE_GetTypeValue(cod)]: massf);
        compute=!(USE_DEM && ftp2); //-Se desactiva cuando se usa DEM y es bound-float. //-Deactivated when DEM is used and is bound-float.
      }

      if(compute){
        //-Density derivative
        const float dvx=velp1.x-velrhop2.x, dvy=velp1.y-velrhop2.y, dvz=velp1.z-velrhop2.z;
        arp1+=(USE_FLOATING? ftmassp2: massf)*(dvx*frx+dvy*fry+dvz*frz);

        {//===== Viscosity ===== 
          const float dot=drx*dvx + dry*dvy + drz*dvz;
          const float dot_rr2=dot/(rr2+CTE.eta2);
          visc=max(dot_rr2,visc); 
        }
      }
    }
  }
}

//------------------------------------------------------------------------------
/// Realiza interaccion entre particulas. Bound-Fluid/Float
/// Particle interaction. Bound-Fluid/Float
//------------------------------------------------------------------------------
template<bool psimple,TpKernel tker,TpFtMode ftmode> __global__ void KerInteractionForcesBound
  (unsigned n,int hdiv,uint4 nc,const int2 *begincell,int3 cellzero,const unsigned *dcell
  ,const float *ftomassp
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop,const word *code,const unsigned *idp
  ,float *viscdt,float *ar)
{
  unsigned p1=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of particle.
  if(p1<n){
    float visc=0,arp1=0;

    //-Carga datos de particula p1.
    //-Loads particle p1 data.
    double3 posdp1;
    float3 posp1,velp1;
    KerGetParticleData<psimple>(p1,posxy,posz,pospress,velrhop,velp1,posdp1,posp1);

    //-Obtiene limites de interaccion
    //-Obtains interaction limits
    int cxini,cxfin,yini,yfin,zini,zfin;
    KerGetInteractionCells(dcell[p1],hdiv,nc,cellzero,cxini,cxfin,yini,yfin,zini,zfin);

    //-Interaccion de Contorno con Fluidas.
    //-Boundary-Fluid interaction.
    for(int z=zini;z<zfin;z++){
      int zmod=(nc.w)*z+(nc.w*nc.z+1);//-Le suma Nct+1 que es la primera celda de fluido. //-Adds Nct + 1 which is the first cell fluid.
      for(int y=yini;y<yfin;y++){
        int ymod=zmod+nc.x*y;
        unsigned pini,pfin=0;
        for(int x=cxini;x<cxfin;x++){
          int2 cbeg=begincell[x+ymod];
          if(cbeg.y){
            if(!pfin)pini=cbeg.x;
            pfin=cbeg.y;
          }
        }
        if(pfin)KerInteractionForcesBoundBox<psimple,tker,ftmode> (p1,pini,pfin,ftomassp,posxy,posz,pospress,velrhop,code,idp,CTE.massf,posdp1,posp1,velp1,arp1,visc);
      }
    }
    //-Almacena resultados.
    //-Stores results.
    if(arp1 || visc){
      ar[p1]+=arp1;
      if(visc>viscdt[p1])viscdt[p1]=visc;
    }
  }
}

//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Realiza la interaccion de una particula con un conjunto de ellas. Bound-Fluid/Float
/// Interaction of a particle with a set of particles (Bound-Fluid). -��//MP
//------------------------------------------------------------------------------
template<bool psimple,TpKernel tker,TpFtMode ftmode,bool shift> __device__ void KerInteractionForcesBoundBoxMP
  (unsigned p1,const unsigned &pini,const unsigned &pfin
  ,const float *ftomassp
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop,const word *code,const unsigned* idp
  ,double3 posdp1,float3 posp1,float3 velp1,float rhopp1,float &arp1,float &visc,volatile StPhaseBoundData *bounddata
  ,TpShifting tshifting,float &shiftdetectp1)
{
  for(int p2=pini;p2<pfin;p2++){
    float drx,dry,drz;
    KerGetParticlesDr<psimple>(p2,posxy,posz,pospress,posdp1,posp1,drx,dry,drz);
    float rr2=drx*drx+dry*dry+drz*drz;
    if(rr2<=CTE.fourh2 && rr2>=ALMOSTZERO){
      //-Wendland or Cubic Spline kernel.
      float frx,fry,frz,wab;
      if(tker==KERNEL_Wendland)KerGetKernelShift(rr2,drx,dry,drz,frx,fry,frz,wab);
      else if(tker==KERNEL_Cubic)KerGetKernelCubicShift(rr2,drx,dry,drz,frx,fry,frz,wab);

      const float4 velrhop2=velrhop[p2];
      //-Obtiene masa de particula p2 en caso de existir floatings.
	  float massp2;
	  for(unsigned iphase=0; iphase<CTE.phasecount; iphase++){ //different mass for each for each material as defined in the xml
		if(CODE_GetTypeAndValue(code[p2])==bounddata[iphase].MkValue){
		  massp2=bounddata[iphase].PhaseMass;
		  break;
		}
	  }
      //-Obtains particle mass p2 if there are floating bodies.
	  float ftmassp2;//-Contiene masa de particula floating o massf si es fluid. //-Contains mass of floating body or massf if fluid.
      bool compute=true; //-Se desactiva cuando se usa DEM y es float-float o float-bound. //-Deactivated when DEM is used and is float-float or float-bound.
      if(USE_FLOATING){
        const word cod=code[p2];
        bool ftp2=(CODE_GetType(cod)==CODE_TYPE_FLOATING);
        ftmassp2=(ftp2? ftomassp[CODE_GetTypeValue(cod)]: massp2);
		bool boundtrue= (CODE_GetType(code[p2])==CODE_TYPE_FLOATING) || (CODE_GetType(code[p2])==CODE_TYPE_FIXED) || (CODE_GetType(code[p2])==CODE_TYPE_MOVING);
        compute=!(USE_DEM && ftp2) || (!boundtrue); //-Se desactiva cuando se usa DEM y es bound-float. //-Deactivated when DEM is used and is bound-float or when used with boundary particles.
      }

      if(compute){
        //-Density derivative
        const float dvx=velp1.x-velrhop2.x, dvy=velp1.y-velrhop2.y, dvz=velp1.z-velrhop2.z;
        arp1+=(USE_FLOATING? ftmassp2: massp2)*(dvx*frx+dvy*fry+dvz*frz)*rhopp1/velrhop2.w;

        {//===== Viscosity ===== 
          const float dot=drx*dvx + dry*dvy + drz*dvz;
          const float dot_rr2=dot/(rr2+CTE.eta2);
          visc=max(dot_rr2,visc); 
        }
		//===== Shifting ======
		float massrhop=(USE_FLOATING? ftmassp2: massp2)/velrhop2.w;
		if(shift)shiftdetectp1+=massrhop*wab;
      }
    }
  }
}
//�����������������������������������������������������������������������//MP

//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Realiza interaccion entre particulas. Bound-Fluid/Float
/// Particle interaction. Bound-Fluid/Float -��//MP
//------------------------------------------------------------------------------
template<bool psimple,TpKernel tker,TpFtMode ftmode,bool shift> __global__ void KerInteractionForcesBoundMP
  (unsigned n,int hdiv,uint4 nc,const int2 *begincell,int3 cellzero,const unsigned *dcell
  ,const float *ftomassp
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop,const word *code,const unsigned *idp
  ,float *viscdt,float *ar,StPhaseData *phasedata
  ,TpShifting tshifting,float *shiftdetect)
{
  //-Shared memory for storing material properties
  extern volatile __shared__ StPhaseBoundData bounddata[];
  if(threadIdx.x==0){ //only executed by thread 0
	  for(unsigned i=0; i<CTE.phasecount; i++){
		  bounddata[i].MkValue=phasedata[i].MkValue;
		  bounddata[i].PhaseMass=phasedata[i].PhaseMass;
		  bounddata[i].PhaseType=phasedata[i].PhaseType;
	  }
  }
  __syncthreads();
  unsigned p1=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of particle.
  if(p1<n){
    float visc=0,arp1=0;

    //-Carga datos de particula p1.
    //-Loads particle p1 data.
	float rhopp1;
    double3 posdp1;
    float3 posp1,velp1;
    KerGetParticleDataMP<psimple>(p1,posxy,posz,pospress,velrhop,velp1,rhopp1,posdp1,posp1);

	//-Multiphase variables
	float massp1;
	for(unsigned iphase=0; iphase<CTE.phasecount; iphase++){ //added selection for material properties
		if(CODE_GetTypeAndValue(code[p1])==bounddata[iphase].MkValue){
		  massp1=bounddata[iphase].PhaseMass;
		  break;
		}
	}

	//-Shifting variables
    float shiftdetectp1;
    if(shift){
      shiftdetectp1=(tker==KERNEL_Wendland? massp1*CTE.awen/rhopp1:massp1*CTE.cubic_a2/rhopp1);
    }

    //-Obtiene limites de interaccion
    //-Obtains interaction limits
    int cxini,cxfin,yini,yfin,zini,zfin;
    KerGetInteractionCells(dcell[p1],hdiv,nc,cellzero,cxini,cxfin,yini,yfin,zini,zfin);

    //-Interaccion de Contorno con Fluidas.
    //-Boundary-Fluid interaction.
    for(int z=zini;z<zfin;z++){
      int zmod=(nc.w)*z+(nc.w*nc.z+1);//-Le suma Nct+1 que es la primera celda de fluido. //-Adds Nct + 1 which is the first cell fluid.
      for(int y=yini;y<yfin;y++){
        int ymod=zmod+nc.x*y;
        unsigned pini,pfin=0;
        for(int x=cxini;x<cxfin;x++){
          int2 cbeg=begincell[x+ymod];
          if(cbeg.y){
            if(!pfin)pini=cbeg.x;
            pfin=cbeg.y;
          }
        }
        if(pfin)KerInteractionForcesBoundBoxMP<psimple,tker,ftmode,shift> (p1,pini,pfin,ftomassp,posxy,posz,pospress,velrhop,code,idp,posdp1,posp1,velp1,rhopp1,arp1,visc,bounddata,tshifting,shiftdetectp1);
      }
    }
	//-Interaccion con contorno.
	//-Interaction with boundaries for shifting.
	float dummy; //Dummy variable created to replace ar as NULL is unusable in device kernels
	for(int z=zini;z<zfin;z++){
	  int zmod=(nc.w)*z;
	  for(int y=yini;y<yfin;y++){
		int ymod=zmod+nc.x*y;
		unsigned pini,pfin=0;
		for(int x=cxini;x<cxfin;x++){
		  int2 cbeg=begincell[x+ymod];
		  if(cbeg.y){
			if(!pfin)pini=cbeg.x;
			pfin=cbeg.y;
		  }
		}
		if(pfin)KerInteractionForcesBoundBoxMP<psimple,tker,ftmode,shift> (p1,pini,pfin,ftomassp,posxy,posz,pospress,velrhop,code,idp,posdp1,posp1,velp1,rhopp1,dummy,visc,bounddata,tshifting,shiftdetectp1);
	  }
	}
    //-Almacena resultados.
    //-Stores results.
    if(shift || arp1 || visc){
	  if(shift)shiftdetect[p1]=shiftdetectp1;
      ar[p1]+=arp1;
      if(visc>viscdt[p1])viscdt[p1]=visc;
    }
  }
}
//�����������������������������������������������������������������������//MP

//------------------------------------------------------------------------------
/// Realiza la interaccion de una particula con un conjunto de ellas. (Fluid/Float-Fluid/Float/Bound)
/// Interaction of a particle with a set of particles. (Fluid/Float-Fluid/Float/Bound)
//------------------------------------------------------------------------------
template<bool psimple,TpKernel tker,TpFtMode ftmode,bool lamsps,TpDeltaSph tdelta,bool shift> __device__ void KerInteractionForcesFluidBox
  (bool boundp2,unsigned p1,const unsigned &pini,const unsigned &pfin,float visco
  ,const float *ftomassp,const float2 *tauff
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop,const word *code,const unsigned *idp
  ,float massp2,float ftmassp1,bool ftp1
  ,double3 posdp1,float3 posp1,float3 velp1,float pressp1,float rhopp1
  ,const float2 &taup1_xx_xy,const float2 &taup1_xz_yy,const float2 &taup1_yz_zz
  ,float2 &grap1_xx_xy,float2 &grap1_xz_yy,float2 &grap1_yz_zz
  ,float3 &acep1,float &arp1,float &visc,float &deltap1
  ,TpShifting tshifting,float3 &shiftposp1,float &shiftdetectp1)
{
  for(int p2=pini;p2<pfin;p2++){
    float drx,dry,drz,pressp2;
    KerGetParticlesDr<psimple> (p2,posxy,posz,pospress,posdp1,posp1,drx,dry,drz,pressp2);
    float rr2=drx*drx+dry*dry+drz*drz;
    if(rr2<=CTE.fourh2 && rr2>=ALMOSTZERO){
      //-Wendland or Cubic Spline kernel.
      float frx,fry,frz;
      if(tker==KERNEL_Wendland)KerGetKernel(rr2,drx,dry,drz,frx,fry,frz);
      else if(tker==KERNEL_Cubic)KerGetKernelCubic(rr2,drx,dry,drz,frx,fry,frz);

      //-Obtiene masa de particula p2 en caso de existir floatings.
      //-Obtains mass of particle p2 if any floating bodies exist.
      bool ftp2;         //-Indica si es floating. //-indicates if it is floating.
      float ftmassp2;    //-Contiene masa de particula floating o massp2 si es bound o fluid. //-Contains mass of floating body or massf if fluid.
      bool compute=true; //-Se desactiva cuando se usa DEM y es float-float o float-bound. //-Deactivated when DEM is used and is float-float or float-bound.
      if(USE_FLOATING){
        const word cod=code[p2];
        ftp2=(CODE_GetType(cod)==CODE_TYPE_FLOATING);
        ftmassp2=(ftp2? ftomassp[CODE_GetTypeValue(cod)]: massp2);
        #ifdef DELTA_HEAVYFLOATING
          if(ftp2 && ftmassp2<=(massp2*1.2f) && (tdelta==DELTA_Dynamic || tdelta==DELTA_DynamicExt))deltap1=FLT_MAX;
        #else
          if(ftp2 && (tdelta==DELTA_Dynamic || tdelta==DELTA_DynamicExt))deltap1=FLT_MAX;
        #endif
        if(ftp2 && shift && tshifting==SHIFT_NoBound)shiftposp1.x=FLT_MAX; //-Con floatings anula shifting. //-Cancels shifting with floating bodies
        compute=!(USE_DEM && ftp1 && (boundp2 || ftp2)); //-Se desactiva cuando se usa DEM y es float-float o float-bound. //-Deactivated when DEM is used and is float-float or float-bound.
      }

      const float4 velrhop2=velrhop[p2];
      
      //===== Aceleration ===== 
      if(compute){
        if(!psimple)pressp2=(CTE.cteb*(powf(velrhop2.w*CTE.ovrhopzero,CTE.gamma)-1.0f));
        const float prs=(pressp1+pressp2)/(rhopp1*velrhop2.w) + (tker==KERNEL_Cubic? KerGetKernelCubicTensil(rr2,rhopp1,pressp1,velrhop2.w,pressp2): 0);
        const float p_vpm=-prs*(USE_FLOATING? ftmassp2*ftmassp1: massp2);
        acep1.x+=p_vpm*frx; acep1.y+=p_vpm*fry; acep1.z+=p_vpm*frz;
      }

      //-Density derivative
      const float dvx=velp1.x-velrhop2.x, dvy=velp1.y-velrhop2.y, dvz=velp1.z-velrhop2.z;
      if(compute)arp1+=(USE_FLOATING? ftmassp2: massp2)*(dvx*frx+dvy*fry+dvz*frz);

      const float cbar=CTE.cs0;
      //-Density derivative (DeltaSPH Molteni)
      if((tdelta==DELTA_Dynamic || tdelta==DELTA_DynamicExt)){
        const float rhop1over2=rhopp1/velrhop2.w;
        const float visc_densi=CTE.delta2h*cbar*(rhop1over2-1.f)/(rr2+CTE.eta2);
        const float dot3=(drx*frx+dry*fry+drz*frz);
        const float delta=visc_densi*dot3*(USE_FLOATING? ftmassp2: massp2);
        if(USE_FLOATING)deltap1=(boundp2 || deltap1==FLT_MAX? FLT_MAX: deltap1+delta); //-Con floating bodies entre el fluido. //-For floating bodies within the fluid
        else deltap1=(boundp2? FLT_MAX: deltap1+delta);
      }

      //-Shifting correction
      if(shift && shiftposp1.x!=FLT_MAX){
        const float massrhop=(USE_FLOATING? ftmassp2: massp2)/velrhop2.w;
        const bool noshift=(boundp2 && (tshifting==SHIFT_NoBound || (tshifting==SHIFT_NoFixed && CODE_GetType(code[p2])==CODE_TYPE_FIXED)));
        shiftposp1.x=(noshift? FLT_MAX: shiftposp1.x+massrhop*frx); //-Con boundary anula shifting. //-Reomves shifting for the boundaries
        shiftposp1.y+=massrhop*fry;
        shiftposp1.z+=massrhop*frz;
        shiftdetectp1-=massrhop*(drx*frx+dry*fry+drz*frz);
      }

      //===== Viscosity ===== 
      if(compute){
        const float dot=drx*dvx + dry*dvy + drz*dvz;
        const float dot_rr2=dot/(rr2+CTE.eta2);
        visc=max(dot_rr2,visc);  //ViscDt=max(dot/(rr2+Eta2),ViscDt);
        if(!lamsps){//-Artificial viscosity 
          if(dot<0){
            const float amubar=CTE.h*dot_rr2;  //amubar=CTE.h*dot/(rr2+CTE.eta2);
            const float robar=(rhopp1+velrhop2.w)*0.5f;
            const float pi_visc=(-visco*cbar*amubar/robar)*(USE_FLOATING? ftmassp2*ftmassp1: massp2);
            acep1.x-=pi_visc*frx; acep1.y-=pi_visc*fry; acep1.z-=pi_visc*frz;
          }
        }
        else{//-Laminar+SPS viscosity 
          {//-Laminar contribution.
            const float robar2=(rhopp1+velrhop2.w);
            const float temp=4.f*visco/((rr2+CTE.eta2)*robar2);  //-Simplificacion de temp=2.0f*visco/((rr2+CTE.eta2)*robar); robar=(rhopp1+velrhop2.w)*0.5f;
            const float vtemp=(USE_FLOATING? ftmassp2: massp2)*temp*(drx*frx+dry*fry+drz*frz);  
            acep1.x+=vtemp*dvx; acep1.y+=vtemp*dvy; acep1.z+=vtemp*dvz;
          }
          //-SPS turbulence model.
          float2 taup2_xx_xy=taup1_xx_xy; //-taup1 siempre es cero cuando p1 no es fluid. //-taup1 is always zero when p1 is not fluid.
          float2 taup2_xz_yy=taup1_xz_yy;
          float2 taup2_yz_zz=taup1_yz_zz;
          if(!boundp2 && (USE_NOFLOATING || !ftp2)){//-Cuando p2 es fluido. //-When p2 is fluid.
            float2 taup2=tauff[p2*3];     taup2_xx_xy.x+=taup2.x; taup2_xx_xy.y+=taup2.y;
                   taup2=tauff[p2*3+1];   taup2_xz_yy.x+=taup2.x; taup2_xz_yy.y+=taup2.y;
                   taup2=tauff[p2*3+2];   taup2_yz_zz.x+=taup2.x; taup2_yz_zz.y+=taup2.y;
          }
          acep1.x+=(USE_FLOATING? ftmassp2*ftmassp1: massp2)*(taup2_xx_xy.x*frx+taup2_xx_xy.y*fry+taup2_xz_yy.x*frz);
          acep1.y+=(USE_FLOATING? ftmassp2*ftmassp1: massp2)*(taup2_xx_xy.y*frx+taup2_xz_yy.y*fry+taup2_yz_zz.x*frz);
          acep1.z+=(USE_FLOATING? ftmassp2*ftmassp1: massp2)*(taup2_xz_yy.x*frx+taup2_yz_zz.x*fry+taup2_yz_zz.y*frz);
          //-Velocity gradients.
          if(USE_NOFLOATING || !ftp1){//-Cuando p1 es fluido. //-When p1 is fluid.
            const float volp2=-(USE_FLOATING? ftmassp2: massp2)/velrhop2.w;
            float dv=dvx*volp2; grap1_xx_xy.x+=dv*frx; grap1_xx_xy.y+=dv*fry; grap1_xz_yy.x+=dv*frz;
                  dv=dvy*volp2; grap1_xx_xy.y+=dv*frx; grap1_xz_yy.y+=dv*fry; grap1_yz_zz.x+=dv*frz;
                  dv=dvz*volp2; grap1_xz_yy.x+=dv*frx; grap1_yz_zz.x+=dv*fry; grap1_yz_zz.y+=dv*frz;
            // to compute tau terms we assume that gradvel.xy=gradvel.dudy+gradvel.dvdx, gradvel.xz=gradvel.dudz+gradvel.dwdx, gradvel.yz=gradvel.dvdz+gradvel.dwdy
            // so only 6 elements are needed instead of 3x3.
          }
        }
      }
    }
  }
}

//------------------------------------------------------------------------------
/// Realiza interaccion entre particulas. Fluid/Float-Fluid/Float or Fluid/Float-Bound
/// Incluye visco artificial/laminar y floatings normales/dem.
/// Interaction between particles. Fluid/Float-Fluid/Float or Fluid/Float-Bound.
/// Includes artificial/laminar viscosity and normal/DEM floating bodies.
//------------------------------------------------------------------------------
template<bool psimple,TpKernel tker,TpFtMode ftmode,bool lamsps,TpDeltaSph tdelta,bool shift> __global__ void KerInteractionForcesFluid
  (unsigned n,unsigned pinit,int hdiv,uint4 nc,unsigned cellfluid,float viscob,float viscof
  ,const int2 *begincell,int3 cellzero,const unsigned *dcell
  ,const float *ftomassp,const float2 *tauff,float2 *gradvelff
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop,const word *code,const unsigned *idp
  ,float *viscdt,float *ar,float3 *ace,float *delta
  ,TpShifting tshifting,float3 *shiftpos,float *shiftdetect)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle
  if(p<n){
    unsigned p1=p+pinit;      //-N� de particula. //-NI of particle
    float visc=0,arp1=0,deltap1=0;
    float3 acep1=make_float3(0,0,0);

    //-Vars para Shifting.
    //-Variables for Shifting.
    float3 shiftposp1;
    float shiftdetectp1;
    if(shift){
      shiftposp1=make_float3(0,0,0);
      shiftdetectp1=0;
    }

    //-Obtiene datos de particula p1 en caso de existir floatings.
    //-Obtains data of particle p1 in case there are floating bodies.
    bool ftp1;       //-Indica si es floating. //-Indicates if it is floating.
    float ftmassp1;  //-Contiene masa de particula floating o 1.0f si es fluid. //-Contains floating particle mass or 1.0f if it is fluid.
    if(USE_FLOATING){
      const word cod=code[p1];
      ftp1=(CODE_GetType(cod)==CODE_TYPE_FLOATING);
      ftmassp1=(ftp1? ftomassp[CODE_GetTypeValue(cod)]: 1.f);
      if(ftp1 && (tdelta==DELTA_Dynamic || tdelta==DELTA_DynamicExt))deltap1=FLT_MAX;
      if(ftp1 && shift)shiftposp1.x=FLT_MAX;  //-Para floatings no se calcula shifting. //-Shifting is not calculated for floating bodies.
    }

    //-Obtiene datos basicos de particula p1.
    //-Obtains basic data of particle p1.
    double3 posdp1;
    float3 posp1,velp1;
    float rhopp1,pressp1;
    KerGetParticleData<psimple>(p1,posxy,posz,pospress,velrhop,velp1,rhopp1,posdp1,posp1,pressp1);
    
    //-Vars para Laminar+SPS
    //-Variables for Laminar+SPS
    float2 taup1_xx_xy,taup1_xz_yy,taup1_yz_zz;
    if(lamsps){
      taup1_xx_xy=tauff[p1*3];
      taup1_xz_yy=tauff[p1*3+1];
      taup1_yz_zz=tauff[p1*3+2];
    }
    //-Vars para Laminar+SPS (calculo).
    //-Variables for Laminar+SPS (computation).
    float2 grap1_xx_xy,grap1_xz_yy,grap1_yz_zz;
    if(lamsps){
      grap1_xx_xy=make_float2(0,0);
      grap1_xz_yy=make_float2(0,0);
      grap1_yz_zz=make_float2(0,0);
    }

    //-Obtiene limites de interaccion
    //-Obtains interaction limits
    int cxini,cxfin,yini,yfin,zini,zfin;
    KerGetInteractionCells(dcell[p1],hdiv,nc,cellzero,cxini,cxfin,yini,yfin,zini,zfin);

    //-Interaccion con Fluidas.
    //-Interaction with fluids.
    for(int z=zini;z<zfin;z++){
      int zmod=(nc.w)*z+cellfluid; //-Le suma donde empiezan las celdas de fluido. //-The sum showing where fluid cells start
      for(int y=yini;y<yfin;y++){
        int ymod=zmod+nc.x*y;
        unsigned pini,pfin=0;
        for(int x=cxini;x<cxfin;x++){
          int2 cbeg=begincell[x+ymod];
          if(cbeg.y){
            if(!pfin)pini=cbeg.x;
            pfin=cbeg.y;
          }
        }
        if(pfin)KerInteractionForcesFluidBox<psimple,tker,ftmode,lamsps,tdelta,shift> (false,p1,pini,pfin,viscof,ftomassp,tauff,posxy,posz,pospress,velrhop,code,idp,CTE.massf,ftmassp1,ftp1,posdp1,posp1,velp1,pressp1,rhopp1,taup1_xx_xy,taup1_xz_yy,taup1_yz_zz,grap1_xx_xy,grap1_xz_yy,grap1_yz_zz,acep1,arp1,visc,deltap1,tshifting,shiftposp1,shiftdetectp1);
      }
    }
    //-Interaccion con contorno.
    //-Interaction with boundaries.
    for(int z=zini;z<zfin;z++){
      int zmod=(nc.w)*z;
      for(int y=yini;y<yfin;y++){
        int ymod=zmod+nc.x*y;
        unsigned pini,pfin=0;
        for(int x=cxini;x<cxfin;x++){
          int2 cbeg=begincell[x+ymod];
          if(cbeg.y){
            if(!pfin)pini=cbeg.x;
            pfin=cbeg.y;
          }
        }
        if(pfin)KerInteractionForcesFluidBox<psimple,tker,ftmode,lamsps,tdelta,shift> (true ,p1,pini,pfin,viscob,ftomassp,tauff,posxy,posz,pospress,velrhop,code,idp,CTE.massb,ftmassp1,ftp1,posdp1,posp1,velp1,pressp1,rhopp1,taup1_xx_xy,taup1_xz_yy,taup1_yz_zz,grap1_xx_xy,grap1_xz_yy,grap1_yz_zz,acep1,arp1,visc,deltap1,tshifting,shiftposp1,shiftdetectp1);
      }
    }
    //-Almacena resultados.
    //-Stores results.
    if(shift||arp1||acep1.x||acep1.y||acep1.z||visc){
      if(tdelta==DELTA_Dynamic&&deltap1!=FLT_MAX)arp1+=deltap1;
      if(tdelta==DELTA_DynamicExt){
        float rdelta=delta[p1];
        delta[p1]=(rdelta==FLT_MAX||deltap1==FLT_MAX? FLT_MAX: rdelta+deltap1);
      }
      ar[p1]+=arp1;
      float3 r=ace[p1]; r.x+=acep1.x; r.y+=acep1.y; r.z+=acep1.z; ace[p1]=r;
      if(visc>viscdt[p1])viscdt[p1]=visc;
      if(lamsps){
        gradvelff[p1*3]=grap1_xx_xy;
        gradvelff[p1*3+1]=grap1_xz_yy;
        gradvelff[p1*3+2]=grap1_yz_zz;
      }
      if(shift){
        shiftpos[p1]=shiftposp1;
        if(shiftdetect)shiftdetect[p1]=shiftdetectp1;
      }
    }
  }
}

//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Realiza la interaccion de una particula con un conjunto de ellas. (Fluid/Float-Fluid/Float/Bound)
/// Interaction of a particle with a set of particles. (Fluid/Float-Fluid/Float/Bound) -��//MP
//------------------------------------------------------------------------------
template<bool psimple,TpKernel tker,TpFtMode ftmode,bool lamsps,TpDeltaSph tdelta,bool shift> __device__ void KerInteractionForcesFluidBoxMP
  (bool boundp2,unsigned p1,const unsigned &pini,const unsigned &pfin,float visco1
  ,const float *ftomassp,const float2 *tauff
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop,const word *code,const unsigned *idp
  ,float ftmassp1,bool ftp1,const float surfc1
  ,double3 posdp1,float3 posp1,float3 velp1,float pressp1,float rhopp1
  ,const float2 &taup1_xx_xy,const float2 &taup1_xz_yy,const float2 &taup1_yz_zz
  ,float2 &grap1_xx_xy,float2 &grap1_xz_yy,float2 &grap1_yz_zz
  ,float3 &acep1,float &arp1,float &visc,float &deltap1
  ,float rhop0p1,unsigned phasetype1,volatile StPhaseData *accdata
  ,TpShifting tshifting,float3 &shiftposp1,float &shiftdetectp1)
{
  for(int p2=pini;p2<pfin;p2++){
    float drx,dry,drz,pressp2;
    KerGetParticlesDr<psimple> (p2,posxy,posz,pospress,posdp1,posp1,drx,dry,drz,pressp2);
    float rr2=drx*drx+dry*dry+drz*drz;
    if(rr2<=CTE.fourh2 && rr2>=ALMOSTZERO){
		//-load unique properties for each phase
	  float rhop02; float cs02; float massp2; unsigned phasetype2; float gamma2; float visco2;
	  for(unsigned iphase=0; iphase<CTE.phasecount; iphase++){ 
		  if(CODE_GetTypeAndValue(code[p2])==accdata[iphase].MkValue){
			  rhop02=accdata[iphase].PhaseRhop0;
			  cs02=accdata[iphase].PhaseCs0;
			  massp2=accdata[iphase].PhaseMass;
			  phasetype2=accdata[iphase].PhaseType;
			  gamma2=accdata[iphase].PhaseGamma;
			  visco2=accdata[iphase].PhaseVisco;
			  break;
		  }
	  }
      //-Wendland or Cubic Spline kernel.
      float frx,fry,frz,wab;
      if(tker==KERNEL_Wendland)KerGetKernelShift(rr2,drx,dry,drz,frx,fry,frz,wab);
      else if(tker==KERNEL_Cubic)KerGetKernelCubicShift(rr2,drx,dry,drz,frx,fry,frz,wab);

      //-Obtiene masa de particula p2 en caso de existir floatings.
      //-Obtains mass of particle p2 if any floating bodies exist.
      bool ftp2;         //-Indica si es floating. //-indicates if it is floating.
      float ftmassp2;    //-Contiene masa de particula floating o massp2 si es bound o fluid. //-Contains mass of floating body or massf if fluid.
      bool compute=true; //-Se desactiva cuando se usa DEM y es float-float o float-bound. //-Deactivated when DEM is used and is float-float or float-bound.
      if(USE_FLOATING){
        const word cod=code[p2];
        ftp2=(CODE_GetType(cod)==CODE_TYPE_FLOATING);
        ftmassp2=(ftp2? ftomassp[CODE_GetTypeValue(cod)]: massp2);
        #ifdef DELTA_HEAVYFLOATING
          if(ftp2 && ftmassp2<=(massp2*1.2f) && (tdelta==DELTA_Dynamic || tdelta==DELTA_DynamicExt))deltap1=FLT_MAX;
        #else
          if(ftp2 && (tdelta==DELTA_Dynamic || tdelta==DELTA_DynamicExt))deltap1=FLT_MAX;
        #endif
        if(ftp2 && shift && tshifting==SHIFT_NoBound)shiftposp1.x=FLT_MAX; //-Con floatings anula shifting. //-Cancels shifting with floating bodies
        compute=!(USE_DEM && ftp1 && (boundp2 || ftp2)); //-Se desactiva cuando se usa DEM y es float-float o float-bound. //-Deactivated when DEM is used and is float-float or float-bound.
      }

      const float4 velrhop2=velrhop[p2];
      
      //===== Aceleration ===== 
      if(compute){
        if(!psimple){
			float b=cs02*cs02*rhop02/gamma2;
			pressp2=(b*(powf(velrhop2.w/rhop02,gamma2)-1.0f));
			if(phasetype2==1)pressp2-=CTE.mpcoef/rhop02*velrhop2.w*velrhop2.w; //-Add cohesion term for multi-phase flows
		}
        const float prs=(pressp1+pressp2)/(rhopp1*velrhop2.w) + (tker==KERNEL_Cubic? KerGetKernelCubicTensil(rr2,rhopp1,pressp1,velrhop2.w,pressp2): 0);
        const float p_vpm=-prs*(USE_FLOATING? ftmassp2*ftmassp1: massp2);
        acep1.x+=p_vpm*frx; acep1.y+=p_vpm*fry; acep1.z+=p_vpm*frz;
		//-Add cohesion term to the momentum equation
		if(phasetype1==1 && phasetype2==1){
			const float rhopmp=2.f*rhop0p1*rhop0p1;
			const float cohterm=CTE.mpcoef*rhopmp/rhop0p1*massp2/(rhopp1*velrhop2.w);
			acep1.x+=cohterm*frx;
			acep1.y+=cohterm*fry; 
			acep1.z+=cohterm*frz;
		}
      }

      //-Density derivative
      const float dvx=velp1.x-velrhop2.x, dvy=velp1.y-velrhop2.y, dvz=velp1.z-velrhop2.z;
      if(compute)arp1+=(USE_FLOATING? ftmassp2: massp2)*(dvx*frx+dvy*fry+dvz*frz)*rhopp1/velrhop2.w; //Altered to take into account density ratio

      const float cbar=cs02;
      //-Density derivative (DeltaSPH Molteni)
      if((tdelta==DELTA_Dynamic || tdelta==DELTA_DynamicExt)){
		  if (phasetype1==phasetype2){
			const float rhop1over2=rhopp1/velrhop2.w;
			const float visc_densi=CTE.delta2h*cbar*(rhop1over2-1.f)/(rr2+CTE.eta2);
			const float dot3=(drx*frx+dry*fry+drz*frz);
			const float delta=visc_densi*dot3*(USE_FLOATING? ftmassp2: massp2);
			if(USE_FLOATING)deltap1=(boundp2 || deltap1==FLT_MAX? FLT_MAX: deltap1+delta); //-Con floating bodies entre el fluido. //-For floating bodies within the fluid
			else deltap1=(boundp2? FLT_MAX: deltap1+delta);
		  }
      }

      ////-Shifting correction
	  const float massrhop=(USE_FLOATING? ftmassp2: massp2)/velrhop2.w;
	  if(shift)	shiftdetectp1+=massrhop*wab;

	  //===== Colour function gradient ===== //used to compute surface tension
	  if (surfc1){
		shiftposp1.x+=massrhop*frx;
		shiftposp1.y+=massrhop*fry;
		shiftposp1.z+=massrhop*frz;
	  }

      //===== Viscosity ===== 
      if(compute){
        const float dot=drx*dvx + dry*dvy + drz*dvz;
        const float dot_rr2=dot/(rr2+CTE.eta2);
        visc=max(dot_rr2,visc);  //ViscDt=max(dot/(rr2+Eta2),ViscDt);
        if(!lamsps){//-Artificial viscosity 
          if(dot<0){
            const float amubar=CTE.h*dot_rr2;  //amubar=CTE.h*dot/(rr2+CTE.eta2);
            const float robar=(rhopp1+velrhop2.w)*0.5f;
            const float pi_visc=(-visco2*cbar*amubar/robar)*(USE_FLOATING? ftmassp2*ftmassp1: massp2);
            acep1.x-=pi_visc*frx; acep1.y-=pi_visc*fry; acep1.z-=pi_visc*frz;
          }
        }
        else{//-Laminar+SPS viscosity 
          {//-Laminar contribution.
            const float robar2=(rhopp1+velrhop2.w);
            const float temp=2.f*(visco1+visco2)/((rr2+CTE.eta2)*robar2*robar2);
            const float vtemp=(USE_FLOATING? ftmassp2: massp2)*temp*(drx*frx+dry*fry+drz*frz);  
            acep1.x+=vtemp*dvx; acep1.y+=vtemp*dvy; acep1.z+=vtemp*dvz;
          }
          //-SPS turbulence model.
          float2 taup2_xx_xy=taup1_xx_xy; //-taup1 siempre es cero cuando p1 no es fluid. //-taup1 is always zero when p1 is not fluid.
          float2 taup2_xz_yy=taup1_xz_yy;
          float2 taup2_yz_zz=taup1_yz_zz;
          if(!boundp2 && (USE_NOFLOATING || !ftp2)){//-Cuando p2 es fluido. //-When p2 is fluid.
            float2 taup2=tauff[p2*3];     taup2_xx_xy.x+=taup2.x; taup2_xx_xy.y+=taup2.y;
                   taup2=tauff[p2*3+1];   taup2_xz_yy.x+=taup2.x; taup2_xz_yy.y+=taup2.y;
                   taup2=tauff[p2*3+2];   taup2_yz_zz.x+=taup2.x; taup2_yz_zz.y+=taup2.y;
          }
          acep1.x+=(USE_FLOATING? ftmassp2*ftmassp1: massp2)*(taup2_xx_xy.x*frx+taup2_xx_xy.y*fry+taup2_xz_yy.x*frz);
          acep1.y+=(USE_FLOATING? ftmassp2*ftmassp1: massp2)*(taup2_xx_xy.y*frx+taup2_xz_yy.y*fry+taup2_yz_zz.x*frz);
          acep1.z+=(USE_FLOATING? ftmassp2*ftmassp1: massp2)*(taup2_xz_yy.x*frx+taup2_yz_zz.x*fry+taup2_yz_zz.y*frz);
          //-Velocity gradients.
          if(USE_NOFLOATING || !ftp1){//-Cuando p1 es fluido. //-When p1 is fluid.
            const float volp2=-(USE_FLOATING? ftmassp2: massp2)/velrhop2.w;
            float dv=dvx*volp2; grap1_xx_xy.x+=dv*frx; grap1_xx_xy.y+=dv*fry; grap1_xz_yy.x+=dv*frz;
                  dv=dvy*volp2; grap1_xx_xy.y+=dv*frx; grap1_xz_yy.y+=dv*fry; grap1_yz_zz.x+=dv*frz;
                  dv=dvz*volp2; grap1_xz_yy.x+=dv*frx; grap1_yz_zz.x+=dv*fry; grap1_yz_zz.y+=dv*frz;
            // to compute tau terms we assume that gradvel.xy=gradvel.dudy+gradvel.dvdx, gradvel.xz=gradvel.dudz+gradvel.dwdx, gradvel.yz=gradvel.dvdz+gradvel.dwdy
            // so only 6 elements are needed instead of 3x3.
          }
        }
      }
    }
  }
}
//�����������������������������������������������������������������������//MP

//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Realiza interaccion entre particulas. Fluid/Float-Fluid/Float or Fluid/Float-Bound
/// Incluye visco artificial/laminar y floatings normales/dem.
/// Interaction between particles. Fluid/Float-Fluid/Float or Fluid/Float-Bound.
/// Includes artificial/laminar viscosity and normal/DEM floating bodies. -��//MP
//------------------------------------------------------------------------------
template<bool psimple,TpKernel tker,TpFtMode ftmode,bool lamsps,TpDeltaSph tdelta,bool shift> __global__ void KerInteractionForcesFluidMP
  (unsigned n,unsigned pinit,int hdiv,uint4 nc,unsigned cellfluid
  ,const int2 *begincell,int3 cellzero,const unsigned *dcell
  ,const float *ftomassp,const float2 *tauff,float2 *gradvelff
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop,const word *code,const unsigned *idp
  ,float *viscdt,float *ar,float3 *ace,float *delta,tsymatrix3f *surf,StPhaseData *phasedata
  ,TpShifting tshifting,float3 *shiftpos,float *shiftdetect)
{
	//Shared memory for storing material properties
  extern volatile __shared__ StPhaseData accdata[]; //Find material properties
  if(threadIdx.x==0){ //only executed by thread 0
	  for(unsigned i=0; i<CTE.phasecount; i++){
		  accdata[i].MkValue=phasedata[i].MkValue;
		  accdata[i].PhaseRhop0=phasedata[i].PhaseRhop0;
		  accdata[i].PhaseCs0=phasedata[i].PhaseCs0;
		  accdata[i].PhaseMass=phasedata[i].PhaseMass;
		  accdata[i].PhaseType=phasedata[i].PhaseType;
		  accdata[i].PhaseGamma=phasedata[i].PhaseGamma;
		  accdata[i].PhaseVisco=phasedata[i].PhaseVisco;
		  accdata[i].PhaseSurf=phasedata[i].PhaseSurf;
	  }
  }
  __syncthreads();
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle
  if(p<n){
    unsigned p1=p+pinit;      //-N� de particula. //-NI of particle
    float visc=0,arp1=0,deltap1=0;
    float3 acep1=make_float3(0,0,0);

	//-Load unique properties for each phase
	float rhop01; float cs01; unsigned phasetype1; float gamma1; float visco1; float massp1; float surfc1=0.f;
	for(unsigned iphase=0; iphase<CTE.phasecount; iphase++){
		if(CODE_GetTypeAndValue(code[p1])==accdata[iphase].MkValue){
		  rhop01=accdata[iphase].PhaseRhop0;
		  cs01=accdata[iphase].PhaseCs0;
		  massp1=accdata[iphase].PhaseMass;
		  phasetype1=accdata[iphase].PhaseType;
		  gamma1=accdata[iphase].PhaseGamma;
		  visco1=accdata[iphase].PhaseVisco;
		  surfc1=phasedata[iphase].PhaseSurf;
		  break;
		}
	}

    //-Obtiene datos basicos de particula p1.
    //-Obtains basic data of particle p1.
    double3 posdp1;
    float3 posp1,velp1;
    float rhopp1,pressp1;
    KerGetParticleDataMP<psimple>(p1,posxy,posz,pospress,velrhop,velp1,rhopp1,posdp1,posp1,pressp1,rhop01,cs01,gamma1,phasetype1);

    //-Vars para Shifting.
    //-Variables for Shifting.
    float3 shiftposp1;
    float shiftdetectp1;
    if(shift){
      shiftposp1=make_float3(0,0,0);
	  shiftdetectp1=(tker==KERNEL_Wendland? massp1*CTE.awen/rhopp1:massp1*CTE.cubic_a2/rhopp1);
    }

    //-Obtiene datos de particula p1 en caso de existir floatings.
    //-Obtains data of particle p1 in case there are floating bodies.
    bool ftp1;       //-Indica si es floating. //-Indicates if it is floating.
    float ftmassp1;  //-Contiene masa de particula floating o 1.0f si es fluid. //-Contains floating particle mass or 1.0f if it is fluid.
    if(USE_FLOATING){
      const word cod=code[p1];
      ftp1=(CODE_GetType(cod)==CODE_TYPE_FLOATING);
      ftmassp1=(ftp1? ftomassp[CODE_GetTypeValue(cod)]: 1.f);
      if(ftp1 && (tdelta==DELTA_Dynamic || tdelta==DELTA_DynamicExt))deltap1=FLT_MAX;
      if(ftp1 && shift)shiftposp1.x=FLT_MAX;  //-Para floatings no se calcula shifting. //-Shifting is not calculated for floating bodies.
    }
    
    //-Vars para Laminar+SPS
    //-Variables for Laminar+SPS
    float2 taup1_xx_xy,taup1_xz_yy,taup1_yz_zz;
    if(lamsps){
      taup1_xx_xy=tauff[p1*3];
      taup1_xz_yy=tauff[p1*3+1];
      taup1_yz_zz=tauff[p1*3+2];
    }
    //-Vars para Laminar+SPS (calculo).
    //-Variables for Laminar+SPS (computation).
    float2 grap1_xx_xy,grap1_xz_yy,grap1_yz_zz;
    if(lamsps){
      grap1_xx_xy=make_float2(0,0);
      grap1_xz_yy=make_float2(0,0);
      grap1_yz_zz=make_float2(0,0);
    }

    //-Obtiene limites de interaccion
    //-Obtains interaction limits
    int cxini,cxfin,yini,yfin,zini,zfin;
    KerGetInteractionCells(dcell[p1],hdiv,nc,cellzero,cxini,cxfin,yini,yfin,zini,zfin);

    //-Interaccion con Fluidas.
    //-Interaction with fluids.
    for(int z=zini;z<zfin;z++){
      int zmod=(nc.w)*z+cellfluid; //-Le suma donde empiezan las celdas de fluido. //-The sum showing where fluid cells start
      for(int y=yini;y<yfin;y++){
        int ymod=zmod+nc.x*y;
        unsigned pini,pfin=0;
        for(int x=cxini;x<cxfin;x++){
          int2 cbeg=begincell[x+ymod];
          if(cbeg.y){
            if(!pfin)pini=cbeg.x;
            pfin=cbeg.y;
          }
        }
        if(pfin)KerInteractionForcesFluidBoxMP<psimple,tker,ftmode,lamsps,tdelta,shift> (false,p1,pini,pfin,visco1,ftomassp,tauff,posxy,posz,pospress,velrhop,code,idp,ftmassp1,ftp1,surfc1,posdp1,posp1,velp1,pressp1,rhopp1,taup1_xx_xy,taup1_xz_yy,taup1_yz_zz,grap1_xx_xy,grap1_xz_yy,grap1_yz_zz,acep1,arp1,visc,deltap1,rhop01,phasetype1,accdata,tshifting,shiftposp1,shiftdetectp1);
      }
    }
    //-Interaccion con contorno.
    //-Interaction with boundaries.
    for(int z=zini;z<zfin;z++){
      int zmod=(nc.w)*z;
      for(int y=yini;y<yfin;y++){
        int ymod=zmod+nc.x*y;
        unsigned pini,pfin=0;
        for(int x=cxini;x<cxfin;x++){
          int2 cbeg=begincell[x+ymod];
          if(cbeg.y){
            if(!pfin)pini=cbeg.x;
            pfin=cbeg.y;
          }
        }
        if(pfin)KerInteractionForcesFluidBoxMP<psimple,tker,ftmode,lamsps,tdelta,shift> (true ,p1,pini,pfin,visco1,ftomassp,tauff,posxy,posz,pospress,velrhop,code,idp,ftmassp1,ftp1,surfc1,posdp1,posp1,velp1,pressp1,rhopp1,taup1_xx_xy,taup1_xz_yy,taup1_yz_zz,grap1_xx_xy,grap1_xz_yy,grap1_yz_zz,acep1,arp1,visc,deltap1,rhop01,phasetype1,accdata,tshifting,shiftposp1,shiftdetectp1);
      }
    }
    //-Almacena resultados.
    //-Stores results.
    if(shift||arp1||acep1.x||acep1.y||acep1.z||visc){
      if(tdelta==DELTA_Dynamic&&deltap1!=FLT_MAX)arp1+=deltap1;
      if(tdelta==DELTA_DynamicExt){
        float rdelta=delta[p1];
        delta[p1]=(rdelta==FLT_MAX||deltap1==FLT_MAX? FLT_MAX: rdelta+deltap1);
      }
      ar[p1]+=arp1;
      float3 r=ace[p1]; r.x+=acep1.x; r.y+=acep1.y; r.z+=acep1.z; ace[p1]=r;
      if(visc>viscdt[p1])viscdt[p1]=visc;
      if(lamsps){
        gradvelff[p1*3]=grap1_xx_xy;
        gradvelff[p1*3+1]=grap1_xz_yy;
        gradvelff[p1*3+2]=grap1_yz_zz;
      }
	  if(shift)shiftdetect[p1]=shiftdetectp1;
	  //-For calculating surface tension
	  if (surfc1){ 
		tsymatrix3f surf1={0,0,0,0,0,0};
		float sigma=0.f;
		float gradcnorm=sqrt(shiftposp1.x*shiftposp1.x+shiftposp1.y*shiftposp1.y+shiftposp1.z*shiftposp1.z);
		float gradcsq=gradcnorm*gradcnorm;
		if (gradcnorm!=0 && gradcnorm==gradcnorm){
			sigma=surfc1/gradcnorm;
			surf1.xx=sigma*(gradcsq-shiftposp1.x*shiftposp1.x);
			surf1.xy=-sigma*shiftposp1.x*shiftposp1.y;
			surf1.xz=-sigma*shiftposp1.x*shiftposp1.z;
			surf1.yy=sigma*(gradcsq-shiftposp1.y*shiftposp1.y);
			surf1.yz=-sigma*shiftposp1.y*shiftposp1.z;
			surf1.zz=sigma*(gradcsq-shiftposp1.z*shiftposp1.z);
		}
		surf[p1]=surf1;
	  }
    }
  }
}
//�����������������������������������������������������������������������//MP

//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Interaction for particle shifting according to Mokos et al. 2016 -��//MP
/// Also computes the surface tension forces
//------------------------------------------------------------------------------
template<bool psimple,TpKernel tker> __device__ void KerRunShiftingBoxMP
  (unsigned p1,const unsigned &pini,const unsigned &pfin
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop
  ,const tsymatrix3f *surf,const word *code,const unsigned *idp,const float *shiftdetect
  ,double3 posdp1,float3 posp1,float3 velp1,const float rhopp1,const float surfcoef1
  ,const tsymatrix3f surf1,TpShifting tshifting,bool &restrshift,float shiftdetectp1
  ,unsigned phasetype1,volatile StPhaseShiftData *shiftdata
  ,float3 &acep1,float3 &shiftposp1,float3 &norm1,float &pdiv,float &pdivall)
{
  for(int p2=pini;p2<pfin;p2++){
    float drx,dry,drz;
    KerGetParticlesDr<psimple> (p2,posxy,posz,pospress,posdp1,posp1,drx,dry,drz);
    float rr2=drx*drx+dry*dry+drz*drz;
    if(rr2<=CTE.fourh2 && rr2>=ALMOSTZERO){
	 //-Load unique properties for each phase
	  float massp2; unsigned phasetype2;
	  for(unsigned iphase=0; iphase<CTE.phasecount; iphase++){ //added value selection for the phases
		  if(CODE_GetTypeAndValue(code[p2])==shiftdata[iphase].MkValue){
			  massp2=shiftdata[iphase].PhaseMass;
			  phasetype2=shiftdata[iphase].PhaseType;
			  break;
		  }
	  }
      //-Wendland or Cubic Spline kernel.
      float frx,fry,frz,wab;
      if(tker==KERNEL_Wendland)KerGetKernelShift(rr2,drx,dry,drz,frx,fry,frz,wab);
      else if(tker==KERNEL_Cubic)KerGetKernelCubicShift(rr2,drx,dry,drz,frx,fry,frz,wab);

	  //-Obtain particle data
	  const float4 velrhop2=velrhop[p2];
	  float vol2=massp2/velrhop2.w;
	  tsymatrix3f surf2={0,0,0,0,0,0};
	  if (surfcoef1)surf2=surf[p2];

	  //-Tensile Instability - Monaghan - not used
	  float tens;
      if(tker==KERNEL_Wendland)KerGetTensWendland(wab,tens);
      else if(tker==KERNEL_Cubic)KerGetTensCubic(wab,tens);

	  //-Different shifting options
	  float shiftdetectp2;
	  const bool noshift=(CODE_GetType(code[p2])!=CODE_TYPE_FLUID && tshifting==SHIFT_NoBound) || (tshifting==SHIFT_NoFixed && CODE_GetType(code[p2])==CODE_TYPE_FIXED);
	  if(noshift){shiftdetectp2=shiftdetectp1; restrshift=true;}
	  else if (tshifting)shiftdetectp2=shiftdetect[p2];

	  //-Concentration gradient
	  float consub=shiftdetectp2-shiftdetectp1;
	  shiftposp1.x+=consub*vol2*frx;//*(1.f+tens); //Enable tensile instability if needed
	  shiftposp1.y+=consub*vol2*fry;//*(1.f+tens);
	  shiftposp1.z+=consub*vol2*frz;//*(1.f+tens);

	  //-Particle Divergence
	  pdivall-=vol2*(drx*frx+dry*fry+drz*frz);
	  if(phasetype1==phasetype2) {
		norm1.x+=consub*vol2*frx;//*(1.f+tens);
		norm1.y+=consub*vol2*fry;//*(1.f+tens);
		norm1.z+=consub*vol2*frz;//*(1.f+tens);
		pdiv-=vol2*(drx*frx+dry*fry+drz*frz);
	  }

	  //===== Surface Tension =====
	  if (surfcoef1){
		tsymatrix3f temp;
		temp.xx=vol2*(surf1.xx+surf2.xx)/rhopp1;
		temp.xy=vol2*(surf1.xy+surf2.xy)/rhopp1;
		temp.xz=vol2*(surf1.xz+surf2.xz)/rhopp1;
		temp.yy=vol2*(surf1.yy+surf2.yy)/rhopp1;
		temp.yz=vol2*(surf1.yz+surf2.yz)/rhopp1;
		temp.zz=vol2*(surf1.zz+surf2.zz)/rhopp1;
		acep1.x+=temp.xx*frx+temp.xy*fry+temp.xz*frz;
		acep1.y+=temp.xy*frx+temp.yy*fry+temp.yz*frz;
		acep1.z+=temp.xz*frx+temp.yz*fry+temp.zz*frz;
	  }
	}
  }
}
//�����������������������������������������������������������������������//MP

//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Particle shifting according to Mokos et al. 2016. -��//MP
/// Also computes surface tension forces
//------------------------------------------------------------------------------
template<bool psimple,TpKernel tker,bool sim2d> __global__ void KerRunShiftingMP
  (unsigned n,unsigned pinit,int hdiv,uint4 nc,unsigned cellfluid
  ,const int2 *begincell,int3 cellzero,const unsigned *dcell
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,const float4 *velrhop,const word *code,const unsigned *idp,float3 *ace
  ,tsymatrix3f *surf,StPhaseData *phasedata,TpShifting tshifting,float shiftcoef,float shiftfs
  ,float3 *shiftpos,const float *shiftdetect,double dt)
{
  //Shared memory for storing material properties
  extern volatile __shared__ StPhaseShiftData shiftdata[]; //Find material properties for shifting
  if(threadIdx.x==0){ //only executed by thread 0
	  for(unsigned i=0; i<CTE.phasecount; i++){
		  shiftdata[i].MkValue=phasedata[i].MkValue;
		  shiftdata[i].PhaseMass=phasedata[i].PhaseMass;
		  shiftdata[i].PhaseType=phasedata[i].PhaseType;
		  shiftdata[i].PhaseSurf=phasedata[i].PhaseSurf;
	  }
  }
  __syncthreads();
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle
  if(p<n){
    unsigned p1=p+pinit;      //-N� de particula. //-NI of particle
    float3 acep1=make_float3(ace[p1].x,ace[p1].y,ace[p1].z);

	//-Load unique properties for each phase
	unsigned phasetype1; float surfcoef1=0.f;
	for(unsigned iphase=0; iphase<CTE.phasecount; iphase++){ 
		if(CODE_GetTypeAndValue(code[p1])==shiftdata[iphase].MkValue){
		  phasetype1=shiftdata[iphase].PhaseType;
		  surfcoef1=shiftdata[iphase].PhaseSurf;
		  break;
		}
	}

	//-Obtains basic data of particle p1.
	float3 shiftposp1=make_float3(0,0,0);
	float3 norm1=make_float3(0,0,0);
	bool restrshift=false;
	float pdiv=0,pdivall=0,shiftdetectp1=0;
    if(tshifting) shiftdetectp1=shiftdetect[p1];
    double3 posdp1;
    float3 posp1,velp1;
    float rhopp1;
    tsymatrix3f surf1={0,0,0,0,0,0};
	if(surfcoef1) surf1=surf[p1];
    KerGetParticleDataMP<psimple>(p1,posxy,posz,pospress,velrhop,velp1,rhopp1,posdp1,posp1);

	//-Obtains interaction limits
    int cxini,cxfin,yini,yfin,zini,zfin;
    KerGetInteractionCells(dcell[p1],hdiv,nc,cellzero,cxini,cxfin,yini,yfin,zini,zfin);

	//-Interaction with fluids.
    for(int z=zini;z<zfin;z++){
      int zmod=(nc.w)*z+cellfluid; //-Le suma donde empiezan las celdas de fluido. //-The sum showing where fluid cells start
      for(int y=yini;y<yfin;y++){
        int ymod=zmod+nc.x*y;
        unsigned pini,pfin=0;
        for(int x=cxini;x<cxfin;x++){
          int2 cbeg=begincell[x+ymod];
          if(cbeg.y){
            if(!pfin)pini=cbeg.x;
            pfin=cbeg.y;
          }
        }
        if(pfin)KerRunShiftingBoxMP<psimple,tker> (p1,pini,pfin,posxy,posz,pospress,velrhop,surf,code,idp,shiftdetect,posdp1,posp1,velp1,rhopp1,surfcoef1,surf1,tshifting,restrshift,shiftdetectp1,phasetype1,shiftdata,acep1,shiftposp1,norm1,pdiv,pdivall);
      }
    }
	//-Interaction with boundaries.
    for(int z=zini;z<zfin;z++){
      int zmod=(nc.w)*z; 
      for(int y=yini;y<yfin;y++){
        int ymod=zmod+nc.x*y;
        unsigned pini,pfin=0;
        for(int x=cxini;x<cxfin;x++){
          int2 cbeg=begincell[x+ymod];
          if(cbeg.y){
            if(!pfin)pini=cbeg.x;
            pfin=cbeg.y;
          }
        }
        if(pfin)KerRunShiftingBoxMP<psimple,tker> (p1,pini,pfin,posxy,posz,pospress,velrhop,surf,code,idp,shiftdetect,posdp1,posp1,velp1,rhopp1,surfcoef1,surf1,tshifting,restrshift,shiftdetectp1,phasetype1,shiftdata,acep1,shiftposp1,norm1,pdiv,pdivall);
      }
    }

	//-Diffusion coefficient for shifting by Skillen et al.
	const float velsh=sqrt(velp1.x*velp1.x+velp1.y*velp1.y+velp1.z*velp1.z);
	const float acemaxl=sqrt(acep1.x*acep1.x+acep1.y*acep1.y+acep1.z*acep1.z);
	float diffc=0.5f*shiftcoef*velsh*CTE.h*float(dt)/CTE.cfl;
	float diffc2=-0.5f*sqrt(acemaxl)*float(dt)*(CTE.fourh2/4.f)/sqrt(CTE.h);	

	//-Free Surface Term
    float3 congr1=make_float3(0,0,0);
	if(phasetype1!=1 && ((pdiv<shiftfs) || pdiv!=pdivall))KerShiftingFreeSurfaceMP(sim2d,norm1,congr1);
	else{congr1.x=shiftposp1.x; congr1.y=shiftposp1.y; congr1.z=shiftposp1.z;}

    //-Sum results together / Almacena resultados.
	if (restrshift){
		congr1.x=0.f; 
		congr1.y=0.f; 
		congr1.z=0.f;
	}
	else{
		congr1.x*=diffc; 
		congr1.y*=diffc; 
		congr1.z*=diffc;
	}
    if(tshifting){
		float3 r=shiftpos[p1]; 
		r.x+=congr1.x; 
		r.y+=congr1.y; 
		r.z+=congr1.z; 
		shiftpos[p1]=r;
    }
    float3 r2=ace[p1]; r2.x=acep1.x; r2.y=acep1.y; r2.z=acep1.z; ace[p1]=r2;
  }
}
//�����������������������������������������������������������������������//MP

//==============================================================================
/// Collects kernel information.
//==============================================================================
template<bool psimple,TpKernel tker,TpFtMode ftmode,bool lamsps,TpDeltaSph tdelta,bool shift> void Interaction_ForcesT_KerInfo
  (StKerInfo *kerinfo)
{
#if CUDART_VERSION >= 6050
  {
    typedef void (*fun_ptr)(unsigned,unsigned,int,uint4,unsigned,float,float,const int2*,int3,const unsigned*,const float*,const float2*,float2*,const double2*,const double*,const float4*,const float4*,const word*,const unsigned*,float*,float*,float3*,float*,TpShifting,float3*,float*);
    fun_ptr ptr=&KerInteractionForcesFluid<psimple,tker,ftmode,lamsps,tdelta,shift>;
    int qblocksize=0,mingridsize=0;
    cudaOccupancyMaxPotentialBlockSize(&mingridsize,&qblocksize,(void*)ptr,0,0);
    struct cudaFuncAttributes attr;
    cudaFuncGetAttributes(&attr,(void*)ptr);
    kerinfo->forcesfluid_bs=qblocksize;
    kerinfo->forcesfluid_rg=attr.numRegs;
    kerinfo->forcesfluid_bsmax=attr.maxThreadsPerBlock;
    //printf(">> KerInteractionForcesFluid  blocksize:%u (%u)\n",qblocksize,0);
  }
  {
    typedef void (*fun_ptr)(unsigned,int,uint4,const int2*,int3,const unsigned*,const float*,const double2*,const double*,const float4*,const float4*,const word*,const unsigned*,float*,float*);
    fun_ptr ptr=&KerInteractionForcesBound<psimple,tker,ftmode>;
    int qblocksize=0,mingridsize=0;
    cudaOccupancyMaxPotentialBlockSize(&mingridsize,&qblocksize,(void*)ptr,0,0);
    struct cudaFuncAttributes attr;
    cudaFuncGetAttributes(&attr,(void*)ptr);
    kerinfo->forcesbound_bs=qblocksize;
    kerinfo->forcesbound_rg=attr.numRegs;
    kerinfo->forcesbound_bsmax=attr.maxThreadsPerBlock;
    //printf(">> KerInteractionForcesBound  blocksize:%u (%u)\n",qblocksize,0);
  }
  CheckErrorCuda("Error collecting kernel information.");
#endif
}

//==============================================================================
/// Interaccion para el calculo de fuerzas.
/// Interaction for the force computation.
//==============================================================================
template<bool psimple,TpKernel tker,TpFtMode ftmode,bool lamsps,TpDeltaSph tdelta,bool shift> void Interaction_ForcesT_BsAuto
  (TpCellMode cellmode,float viscob,float viscof,unsigned bsbound,unsigned bsfluid
  ,unsigned np,unsigned npb,unsigned npbok,tuint3 ncells
  ,const int2 *begincell,tuint3 cellmin,const unsigned *dcell
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,const float4 *velrhop,const word *code,const unsigned *idp
  ,const float *ftomassp,const tsymatrix3f *tau,tsymatrix3f *gradvel
  ,float *viscdt,float* ar,float3 *ace,float *delta
  ,TpShifting tshifting,float3 *shiftpos,float *shiftdetect
  ,bool simulate2d,JBlockSizeAuto *bsauto)
{
  if(1){
    //-Executes particle interactions.
    const unsigned npf=np-npb;
    const int hdiv=(cellmode==CELLMODE_H? 2: 1);
    const uint4 nc=make_uint4(ncells.x,ncells.y,ncells.z,ncells.x*ncells.y);
    const unsigned cellfluid=nc.w*nc.z+1;
    const int3 cellzero=make_int3(cellmin.x,cellmin.y,cellmin.z);
    //-Interaccion Fluid-Fluid & Fluid-Bound
    //-Interaction Fluid-Fluid & Fluid-Bound
    if(npf){
      JBlockSizeAutoKer* ker=bsauto->GetKernel(0);
      for(int ct=0;ct<ker->BsNum;ct++)if(ker->IsActive(ct)){
        cudaEvent_t start,stop;
        cudaEventCreate(&start);
        cudaEventCreate(&stop);
        cudaEventRecord(start,0);
        unsigned bsize=ker->GetBs(ct);
        dim3 sgridf=GetGridSize(npf,bsize);
        KerInteractionForcesFluid<psimple,tker,ftmode,lamsps,tdelta,shift> <<<sgridf,bsize>>> (npf,npb,hdiv,nc,cellfluid,viscob,viscof,begincell,cellzero,dcell,ftomassp,(const float2*)tau,(float2*)gradvel,posxy,posz,pospress,velrhop,code,idp,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect);
        cudaEventRecord(stop,0);
        cudaEventSynchronize(stop);
        float time;
        cudaEventElapsedTime(&time,start,stop);
        cudaEventDestroy(start);
        cudaEventDestroy(stop);
        cudaError_t err=cudaGetLastError();
        if(err!=cudaSuccess)time=FLT_MAX;
        ker->SetTime(ct,time);
      }
    }
    //-Interaccion Boundary-Fluid
    //-Interaction Boundary-Fluid
    if(npbok){
      JBlockSizeAutoKer* ker=bsauto->GetKernel(1);
      for(int ct=0;ct<ker->BsNum;ct++)if(ker->IsActive(ct)){
        cudaEvent_t start,stop;
        cudaEventCreate(&start);
        cudaEventCreate(&stop);
        cudaEventRecord(start,0);
        unsigned bsize=ker->GetBs(ct);
        dim3 sgridb=GetGridSize(npbok,bsize);
        KerInteractionForcesBound<psimple,tker,ftmode> <<<sgridb,bsize>>> (npbok,hdiv,nc,begincell,cellzero,dcell,ftomassp,posxy,posz,pospress,velrhop,code,idp,viscdt,ar);
        cudaEventRecord(stop,0);
        cudaEventSynchronize(stop);
        float time;
        cudaEventElapsedTime(&time,start,stop);
        cudaEventDestroy(start);
        cudaEventDestroy(stop);
        cudaError_t err=cudaGetLastError();
        if(err!=cudaSuccess)time=FLT_MAX;
        ker->SetTime(ct,time);
      }
    }
  }
}

//�����������������������������������������������������������������������//MP
//==============================================================================
/// Interaccion para el calculo de fuerzas.
/// Interaction for the force computation. -��//MP
//==============================================================================
template<bool psimple,TpKernel tker,TpFtMode ftmode,bool lamsps,TpDeltaSph tdelta,bool shift> void Interaction_ForcesMPT_BsAuto
  (TpCellMode cellmode,unsigned bsbound,unsigned bsfluid
  ,unsigned np,unsigned npb,unsigned npbok,tuint3 ncells
  ,const int2 *begincell,tuint3 cellmin,const unsigned *dcell
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,const float4 *velrhop,const word *code,const unsigned *idp
  ,const float *ftomassp,const tsymatrix3f *tau,tsymatrix3f *gradvel
  ,float *viscdt,float* ar,float3 *ace,float *delta,tsymatrix3f *surf,StPhaseData *phasedata
  ,TpShifting tshifting,float3 *shiftpos,float *shiftdetect,const unsigned phasecount
  ,bool simulate2d,JBlockSizeAuto *bsauto)
{
  if(1){
    //-Executes particle interactions.
    const unsigned npf=np-npb;
    const int hdiv=(cellmode==CELLMODE_H? 2: 1);
    const uint4 nc=make_uint4(ncells.x,ncells.y,ncells.z,ncells.x*ncells.y);
    const unsigned cellfluid=nc.w*nc.z+1;
    const int3 cellzero=make_int3(cellmin.x,cellmin.y,cellmin.z);
    //-Interaccion Fluid-Fluid & Fluid-Bound
    //-Interaction Fluid-Fluid & Fluid-Bound
    if(npf){
      JBlockSizeAutoKer* ker=bsauto->GetKernel(0);
      for(int ct=0;ct<ker->BsNum;ct++)if(ker->IsActive(ct)){
        cudaEvent_t start,stop;
        cudaEventCreate(&start);
        cudaEventCreate(&stop);
        cudaEventRecord(start,0);
        unsigned bsize=ker->GetBs(ct);
        dim3 sgridf=GetGridSize(npf,bsize);
        KerInteractionForcesFluidMP<psimple,tker,ftmode,lamsps,tdelta,shift> <<<sgridf,bsize,phasecount*sizeof(StPhaseData)>>> (npf,npb,hdiv,nc,cellfluid,begincell,cellzero,dcell,ftomassp,(const float2*)tau,(float2*)gradvel,posxy,posz,pospress,velrhop,code,idp,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect);
        cudaEventRecord(stop,0);
        cudaEventSynchronize(stop);
        float time;
        cudaEventElapsedTime(&time,start,stop);
        cudaEventDestroy(start);
        cudaEventDestroy(stop);
        cudaError_t err=cudaGetLastError();
        if(err!=cudaSuccess)time=FLT_MAX;
        ker->SetTime(ct,time);
      }
    }
    //-Interaccion Boundary-Fluid
    //-Interaction Boundary-Fluid
    if(npbok){
      JBlockSizeAutoKer* ker=bsauto->GetKernel(1);
      for(int ct=0;ct<ker->BsNum;ct++)if(ker->IsActive(ct)){
        cudaEvent_t start,stop;
        cudaEventCreate(&start);
        cudaEventCreate(&stop);
        cudaEventRecord(start,0);
        unsigned bsize=ker->GetBs(ct);
        dim3 sgridb=GetGridSize(npbok,bsize);
        KerInteractionForcesBoundMP<psimple,tker,ftmode,shift> <<<sgridb,bsize,phasecount*sizeof(StPhaseBoundData)>>> (npbok,hdiv,nc,begincell,cellzero,dcell,ftomassp,posxy,posz,pospress,velrhop,code,idp,viscdt,ar,phasedata,tshifting,shiftdetect);
        cudaEventRecord(stop,0);
        cudaEventSynchronize(stop);
        float time;
        cudaEventElapsedTime(&time,start,stop);
        cudaEventDestroy(start);
        cudaEventDestroy(stop);
        cudaError_t err=cudaGetLastError();
        if(err!=cudaSuccess)time=FLT_MAX;
        ker->SetTime(ct,time);
      }
    }
  }
}
//�����������������������������������������������������������������������//MP

//�����������������������������������������������������������������������//MP
//==============================================================================
/// Interaction for particle shifting according to Mokos et al. 2016. -��//MP
//==============================================================================
template<bool psimple,TpKernel tker,bool sim2d> void RunShifting_MPT_BsAuto
  (TpCellMode cellmode,unsigned bsbound,unsigned bsfluid
  ,unsigned np,unsigned npb,unsigned npbok,tuint3 ncells
  ,const int2 *begincell,tuint3 cellmin,const unsigned *dcell
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,const float4 *velrhop,const word *code,const unsigned *idp,float3 *ace
  ,tsymatrix3f *surf,StPhaseData *phasedata,TpShifting tshifting,float shiftcoef,float shiftfs
  ,float3 *shiftpos,const float *shiftdetect,const unsigned phasecount
  ,JBlockSizeAuto *bsauto,double dt)
{
    //-Executes particle interactions.
    const unsigned npf=np-npb;
    const int hdiv=(cellmode==CELLMODE_H? 2: 1);
    const uint4 nc=make_uint4(ncells.x,ncells.y,ncells.z,ncells.x*ncells.y);
    const unsigned cellfluid=nc.w*nc.z+1;
    const int3 cellzero=make_int3(cellmin.x,cellmin.y,cellmin.z);
	if(npf){
      JBlockSizeAutoKer* ker=bsauto->GetKernel(0);
      for(int ct=0;ct<ker->BsNum;ct++)if(ker->IsActive(ct)){
        cudaEvent_t start,stop;
        cudaEventCreate(&start);
        cudaEventCreate(&stop);
        cudaEventRecord(start,0);
        unsigned bsize=ker->GetBs(ct);
        dim3 sgridf=GetGridSize(npf,bsize);
        KerRunShiftingMP<psimple,tker,sim2d> <<<sgridf,bsize,phasecount*sizeof(StPhaseShiftData)>>> (npf,npb,hdiv,nc,cellfluid,begincell,cellzero,dcell,posxy,posz,pospress,velrhop,code,idp,ace,surf,phasedata,tshifting,shiftcoef,shiftfs,shiftpos,shiftdetect,dt);
        cudaEventRecord(stop,0);
        cudaEventSynchronize(stop);
        float time;
        cudaEventElapsedTime(&time,start,stop);
        cudaEventDestroy(start);
        cudaEventDestroy(stop);
        cudaError_t err=cudaGetLastError();
        if(err!=cudaSuccess)time=FLT_MAX;
        ker->SetTime(ct,time);
      }
    }
}
//�����������������������������������������������������������������������//MP

//==============================================================================
/// Interaccion para el calculo de fuerzas.
/// Interaction for the force computation.
//==============================================================================
template<bool psimple,TpKernel tker,TpFtMode ftmode,bool lamsps,TpDeltaSph tdelta,bool shift> void Interaction_ForcesT
  (TpCellMode cellmode,float viscob,float viscof,unsigned bsbound,unsigned bsfluid
  ,unsigned np,unsigned npb,unsigned npbok,tuint3 ncells
  ,const int2 *begincell,tuint3 cellmin,const unsigned *dcell
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,const float4 *velrhop,const word *code,const unsigned *idp
  ,const float *ftomassp,const tsymatrix3f *tau,tsymatrix3f *gradvel
  ,float *viscdt,float* ar,float3 *ace,float *delta
  ,TpShifting tshifting,float3 *shiftpos,float *shiftdetect
  ,bool simulate2d,StKerInfo *kerinfo,JBlockSizeAuto *bsauto)
{
  //-Collects kernel information.
  if(kerinfo)Interaction_ForcesT_KerInfo<psimple,tker,ftmode,lamsps,tdelta,shift>(kerinfo);
  else if(bsauto)Interaction_ForcesT_BsAuto<psimple,tker,ftmode,lamsps,tdelta,shift>(cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,bsauto);
  else{
    //-Executes particle interactions.
    const unsigned npf=np-npb;
    const int hdiv=(cellmode==CELLMODE_H? 2: 1);
    const uint4 nc=make_uint4(ncells.x,ncells.y,ncells.z,ncells.x*ncells.y);
    const unsigned cellfluid=nc.w*nc.z+1;
    const int3 cellzero=make_int3(cellmin.x,cellmin.y,cellmin.z);
    //-Interaccion Fluid-Fluid & Fluid-Bound
    //-Interaction Fluid-Fluid & Fluid-Bound
    if(npf){
      dim3 sgridf=GetGridSize(npf,bsfluid);
      //printf("---->bsfluid:%u   ",bsfluid);
      KerInteractionForcesFluid<psimple,tker,ftmode,lamsps,tdelta,shift> <<<sgridf,bsfluid>>> (npf,npb,hdiv,nc,cellfluid,viscob,viscof,begincell,cellzero,dcell,ftomassp,(const float2*)tau,(float2*)gradvel,posxy,posz,pospress,velrhop,code,idp,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect);
    }
    //-Interaccion Boundary-Fluid
    //-Interaction Boundary-Fluid
    if(npbok){
      dim3 sgridb=GetGridSize(npbok,bsbound);
      //printf("bsbound:%u\n",bsbound);
      KerInteractionForcesBound<psimple,tker,ftmode> <<<sgridb,bsbound>>> (npbok,hdiv,nc,begincell,cellzero,dcell,ftomassp,posxy,posz,pospress,velrhop,code,idp,viscdt,ar);
    }
  }
}
//==============================================================================
template<bool psimple,TpKernel tker,TpFtMode ftmode,bool lamsps> void Interaction_Forces_t2(TpDeltaSph tdelta,TpCellMode cellmode
  ,float viscob,float viscof,unsigned bsbound,unsigned bsfluid
  ,unsigned np,unsigned npb,unsigned npbok,tuint3 ncells
  ,const int2 *begincell,tuint3 cellmin,const unsigned *dcell
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,const float4 *velrhop,const word *code,const unsigned *idp
  ,const float *ftomassp,const tsymatrix3f *tau,tsymatrix3f *gradvel
  ,float *viscdt,float* ar,float3 *ace,float *delta
  ,TpShifting tshifting,float3 *shiftpos,float *shiftdetect
  ,bool simulate2d,StKerInfo *kerinfo,JBlockSizeAuto *bsauto)
{
  if(tshifting){                const bool shift=true;
    if(tdelta==DELTA_None)      Interaction_ForcesT<psimple,tker,ftmode,lamsps,DELTA_None,shift>       (cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
    if(tdelta==DELTA_Dynamic)   Interaction_ForcesT<psimple,tker,ftmode,lamsps,DELTA_Dynamic,shift>    (cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
    if(tdelta==DELTA_DynamicExt)Interaction_ForcesT<psimple,tker,ftmode,lamsps,DELTA_DynamicExt,shift> (cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
  }
  else{                         const bool shift=false;
    if(tdelta==DELTA_None)      Interaction_ForcesT<psimple,tker,ftmode,lamsps,DELTA_None,shift>       (cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
    if(tdelta==DELTA_Dynamic)   Interaction_ForcesT<psimple,tker,ftmode,lamsps,DELTA_Dynamic,shift>    (cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
    if(tdelta==DELTA_DynamicExt)Interaction_ForcesT<psimple,tker,ftmode,lamsps,DELTA_DynamicExt,shift> (cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
  }
}
//==============================================================================
template<bool psimple,TpKernel tker,TpFtMode ftmode> void Interaction_Forces_t1(bool lamsps,TpDeltaSph tdelta,TpCellMode cellmode
  ,float viscob,float viscof,unsigned bsbound,unsigned bsfluid
  ,unsigned np,unsigned npb,unsigned npbok,tuint3 ncells
  ,const int2 *begincell,tuint3 cellmin,const unsigned *dcell
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,const float4 *velrhop,const word *code,const unsigned *idp
  ,const float *ftomassp,const tsymatrix3f *tau,tsymatrix3f *gradvel
  ,float *viscdt,float* ar,float3 *ace,float *delta
  ,TpShifting tshifting,float3 *shiftpos,float *shiftdetect
  ,bool simulate2d,StKerInfo *kerinfo,JBlockSizeAuto *bsauto)
{
  if(lamsps)Interaction_Forces_t2<psimple,tker,ftmode,true>  (tdelta,cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
  else      Interaction_Forces_t2<psimple,tker,ftmode,false> (tdelta,cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
}
//==============================================================================
void Interaction_Forces(bool psimple,TpKernel tkernel,bool floating,bool usedem,bool lamsps
  ,TpDeltaSph tdelta,TpCellMode cellmode
  ,float viscob,float viscof,unsigned bsbound,unsigned bsfluid
  ,unsigned np,unsigned npb,unsigned npbok,tuint3 ncells
  ,const int2 *begincell,tuint3 cellmin,const unsigned *dcell
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,const float4 *velrhop,const word *code,const unsigned *idp
  ,const float *ftomassp,const tsymatrix3f *tau,tsymatrix3f *gradvel
  ,float *viscdt,float* ar,float3 *ace,float *delta
  ,TpShifting tshifting,float3 *shiftpos,float *shiftdetect
  ,bool simulate2d,StKerInfo *kerinfo,JBlockSizeAuto *bsauto)
{
  if(tkernel==KERNEL_Wendland){    const TpKernel tker=KERNEL_Wendland;
    if(psimple){      const bool psimple=true;
      if(!floating)   Interaction_Forces_t1<psimple,tker,FTMODE_None> (lamsps,tdelta,cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
      else if(!usedem)Interaction_Forces_t1<psimple,tker,FTMODE_Sph>  (lamsps,tdelta,cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
      else            Interaction_Forces_t1<psimple,tker,FTMODE_Dem>  (lamsps,tdelta,cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
    }else{            const bool psimple=false;
      if(!floating)   Interaction_Forces_t1<psimple,tker,FTMODE_None> (lamsps,tdelta,cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
      else if(!usedem)Interaction_Forces_t1<psimple,tker,FTMODE_Sph>  (lamsps,tdelta,cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
      else            Interaction_Forces_t1<psimple,tker,FTMODE_Dem>  (lamsps,tdelta,cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
    }
  }else if(tkernel==KERNEL_Cubic){ const TpKernel tker=KERNEL_Cubic;
    if(psimple){      const bool psimple=true;
      if(!floating)   Interaction_Forces_t1<psimple,tker,FTMODE_None> (lamsps,tdelta,cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
      else if(!usedem)Interaction_Forces_t1<psimple,tker,FTMODE_Sph>  (lamsps,tdelta,cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
      else            Interaction_Forces_t1<psimple,tker,FTMODE_Dem>  (lamsps,tdelta,cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
    }else{            const bool psimple=false;
      if(!floating)   Interaction_Forces_t1<psimple,tker,FTMODE_None> (lamsps,tdelta,cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
      else if(!usedem)Interaction_Forces_t1<psimple,tker,FTMODE_Sph>  (lamsps,tdelta,cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
      else            Interaction_Forces_t1<psimple,tker,FTMODE_Dem>  (lamsps,tdelta,cellmode,viscob,viscof,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,tshifting,shiftpos,shiftdetect,simulate2d,kerinfo,bsauto);
    }
  }
}

//�����������������������������������������������������������������������//MP
//==============================================================================
/// Interaccion para el calculo de fuerzas.
/// Interaction for the force computation. -��//MP
//==============================================================================
template<bool psimple,TpKernel tker,TpFtMode ftmode,bool lamsps,TpDeltaSph tdelta,bool shift> void Interaction_ForcesMPT
  (TpCellMode cellmode,unsigned bsbound,unsigned bsfluid
  ,unsigned np,unsigned npb,unsigned npbok,tuint3 ncells
  ,const int2 *begincell,tuint3 cellmin,const unsigned *dcell
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,const float4 *velrhop,const word *code,const unsigned *idp
  ,const float *ftomassp,const tsymatrix3f *tau,tsymatrix3f *gradvel
  ,float *viscdt,float* ar,float3 *ace,float *delta,tsymatrix3f *surf,StPhaseData *phasedata
  ,TpShifting tshifting,float3 *shiftpos,float *shiftdetect,const unsigned phasecount
  ,bool simulate2d,StKerInfo *kerinfo,JBlockSizeAuto *bsauto)
{
  //-Collects kernel information.
  if(kerinfo)Interaction_ForcesT_KerInfo<psimple,tker,ftmode,lamsps,tdelta,shift>(kerinfo);
  else if(bsauto)Interaction_ForcesMPT_BsAuto<psimple,tker,ftmode,lamsps,tdelta,shift>(cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,bsauto);
  else{
    //-Executes particle interactions.
    const unsigned npf=np-npb;
    const int hdiv=(cellmode==CELLMODE_H? 2: 1);
    const uint4 nc=make_uint4(ncells.x,ncells.y,ncells.z,ncells.x*ncells.y);
    const unsigned cellfluid=nc.w*nc.z+1;
    const int3 cellzero=make_int3(cellmin.x,cellmin.y,cellmin.z);
    //-Interaccion Fluid-Fluid & Fluid-Bound
    //-Interaction Fluid-Fluid & Fluid-Bound
    if(npf){
      dim3 sgridf=GetGridSize(npf,bsfluid);
      //printf("---->bsfluid:%u   ",bsfluid);
      KerInteractionForcesFluidMP<psimple,tker,ftmode,lamsps,tdelta,shift> <<<sgridf,bsfluid,phasecount*sizeof(StPhaseData)>>> (npf,npb,hdiv,nc,cellfluid,begincell,cellzero,dcell,ftomassp,(const float2*)tau,(float2*)gradvel,posxy,posz,pospress,velrhop,code,idp,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect);
    }
    //-Interaccion Boundary-Fluid
    //-Interaction Boundary-Fluid
    if(npbok){
      dim3 sgridb=GetGridSize(npbok,bsbound);
      //printf("bsbound:%u\n",bsbound);
      KerInteractionForcesBoundMP<psimple,tker,ftmode,shift> <<<sgridb,bsbound,phasecount*sizeof(StPhaseBoundData)>>> (npbok,hdiv,nc,begincell,cellzero,dcell,ftomassp,posxy,posz,pospress,velrhop,code,idp,viscdt,ar,phasedata,tshifting,shiftdetect);
    }
  }
}
//==============================================================================
template<bool psimple,TpKernel tker,TpFtMode ftmode,bool lamsps> void Interaction_ForcesMP_t2(TpDeltaSph tdelta,TpCellMode cellmode
  ,unsigned bsbound,unsigned bsfluid
  ,unsigned np,unsigned npb,unsigned npbok,tuint3 ncells
  ,const int2 *begincell,tuint3 cellmin,const unsigned *dcell
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,const float4 *velrhop,const word *code,const unsigned *idp
  ,const float *ftomassp,const tsymatrix3f *tau,tsymatrix3f *gradvel
  ,float *viscdt,float* ar,float3 *ace,float *delta,tsymatrix3f *surf,StPhaseData *phasedata
  ,TpShifting tshifting,float3 *shiftpos,float *shiftdetect,const unsigned phasecount
  ,bool simulate2d,StKerInfo *kerinfo,JBlockSizeAuto *bsauto)
{
  if(tshifting){                const bool shift=true;
    if(tdelta==DELTA_None)      Interaction_ForcesMPT<psimple,tker,ftmode,lamsps,DELTA_None,shift>       (cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
    if(tdelta==DELTA_Dynamic)   Interaction_ForcesMPT<psimple,tker,ftmode,lamsps,DELTA_Dynamic,shift>    (cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
    if(tdelta==DELTA_DynamicExt)Interaction_ForcesMPT<psimple,tker,ftmode,lamsps,DELTA_DynamicExt,shift> (cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
  }
  else{                         const bool shift=false;
    if(tdelta==DELTA_None)      Interaction_ForcesMPT<psimple,tker,ftmode,lamsps,DELTA_None,shift>       (cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
    if(tdelta==DELTA_Dynamic)   Interaction_ForcesMPT<psimple,tker,ftmode,lamsps,DELTA_Dynamic,shift>    (cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
    if(tdelta==DELTA_DynamicExt)Interaction_ForcesMPT<psimple,tker,ftmode,lamsps,DELTA_DynamicExt,shift> (cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
  }
}
//==============================================================================
template<bool psimple,TpKernel tker,TpFtMode ftmode> void Interaction_ForcesMP_t1(bool lamsps,TpDeltaSph tdelta,TpCellMode cellmode
  ,unsigned bsbound,unsigned bsfluid
  ,unsigned np,unsigned npb,unsigned npbok,tuint3 ncells
  ,const int2 *begincell,tuint3 cellmin,const unsigned *dcell
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,const float4 *velrhop,const word *code,const unsigned *idp
  ,const float *ftomassp,const tsymatrix3f *tau,tsymatrix3f *gradvel
  ,float *viscdt,float* ar,float3 *ace,float *delta,tsymatrix3f *surf,StPhaseData *phasedata
  ,TpShifting tshifting,float3 *shiftpos,float *shiftdetect,const unsigned phasecount
  ,bool simulate2d,StKerInfo *kerinfo,JBlockSizeAuto *bsauto)
{
  if(lamsps)Interaction_ForcesMP_t2<psimple,tker,ftmode,true>  (tdelta,cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
  else      Interaction_ForcesMP_t2<psimple,tker,ftmode,false> (tdelta,cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
}
//==============================================================================
void Interaction_ForcesMP(bool psimple,TpKernel tkernel,bool floating,bool usedem,bool lamsps
  ,TpDeltaSph tdelta,TpCellMode cellmode
  ,unsigned bsbound,unsigned bsfluid
  ,unsigned np,unsigned npb,unsigned npbok,tuint3 ncells
  ,const int2 *begincell,tuint3 cellmin,const unsigned *dcell
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,const float4 *velrhop,const word *code,const unsigned *idp
  ,const float *ftomassp,const tsymatrix3f *tau,tsymatrix3f *gradvel
  ,float *viscdt,float* ar,float3 *ace,float *delta,tsymatrix3f *surf,StPhaseData *phasedata
  ,TpShifting tshifting,float3 *shiftpos,float *shiftdetect,const unsigned phasecount
  ,bool simulate2d,StKerInfo *kerinfo,JBlockSizeAuto *bsauto)
{
  if(tkernel==KERNEL_Wendland){    const TpKernel tker=KERNEL_Wendland;
    if(psimple){      const bool psimple=true;
      if(!floating)   Interaction_ForcesMP_t1<psimple,tker,FTMODE_None> (lamsps,tdelta,cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
      else if(!usedem)Interaction_ForcesMP_t1<psimple,tker,FTMODE_Sph>  (lamsps,tdelta,cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
      else            Interaction_ForcesMP_t1<psimple,tker,FTMODE_Dem>  (lamsps,tdelta,cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
    }else{            const bool psimple=false;
      if(!floating)   Interaction_ForcesMP_t1<psimple,tker,FTMODE_None> (lamsps,tdelta,cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
      else if(!usedem)Interaction_ForcesMP_t1<psimple,tker,FTMODE_Sph>  (lamsps,tdelta,cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
      else            Interaction_ForcesMP_t1<psimple,tker,FTMODE_Dem>  (lamsps,tdelta,cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
    }
  }else if(tkernel==KERNEL_Cubic){ const TpKernel tker=KERNEL_Cubic;
    if(psimple){      const bool psimple=true;
      if(!floating)   Interaction_ForcesMP_t1<psimple,tker,FTMODE_None> (lamsps,tdelta,cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
      else if(!usedem)Interaction_ForcesMP_t1<psimple,tker,FTMODE_Sph>  (lamsps,tdelta,cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
      else            Interaction_ForcesMP_t1<psimple,tker,FTMODE_Dem>  (lamsps,tdelta,cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
    }else{            const bool psimple=false;
      if(!floating)   Interaction_ForcesMP_t1<psimple,tker,FTMODE_None> (lamsps,tdelta,cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
      else if(!usedem)Interaction_ForcesMP_t1<psimple,tker,FTMODE_Sph>  (lamsps,tdelta,cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
      else            Interaction_ForcesMP_t1<psimple,tker,FTMODE_Dem>  (lamsps,tdelta,cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ftomassp,tau,gradvel,viscdt,ar,ace,delta,surf,phasedata,tshifting,shiftpos,shiftdetect,phasecount,simulate2d,kerinfo,bsauto);
    }
  }
}
//�����������������������������������������������������������������������//MP

//�����������������������������������������������������������������������//MP
//##############################################################################
//# Kernel for particle shifting interaction according to Mokos et al. 2016 
//##############################################################################
template<bool psimple,TpKernel tker,bool sim2d> void RunShifting_MPT
  (TpCellMode cellmode,unsigned bsbound,unsigned bsfluid
  ,unsigned np,unsigned npb,unsigned npbok,tuint3 ncells
  ,const int2 *begincell,tuint3 cellmin,const unsigned *dcell
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,const float4 *velrhop,const word *code,const unsigned *idp,float3 *ace
  ,tsymatrix3f *surf,StPhaseData *phasedata,TpShifting tshifting,float shiftcoef,float shiftfs
  ,float3 *shiftpos,const float *shiftdetect,const unsigned phasecount
  ,JBlockSizeAuto *bsauto,double dt){

	if(bsauto)RunShifting_MPT_BsAuto<psimple,tker,sim2d>(cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ace,surf,phasedata,tshifting,shiftcoef,shiftfs,shiftpos,shiftdetect,phasecount,bsauto,dt);
	//-Executes particle interactions.
    const unsigned npf=np-npb;
    const int hdiv=(cellmode==CELLMODE_H? 2: 1);
    const uint4 nc=make_uint4(ncells.x,ncells.y,ncells.z,ncells.x*ncells.y);
    const unsigned cellfluid=nc.w*nc.z+1;
    const int3 cellzero=make_int3(cellmin.x,cellmin.y,cellmin.z);
    if(npf){
      dim3 sgridf=GetGridSize(npf,bsfluid);
      //printf("---->bsfluid:%u   ",bsfluid);
      KerRunShiftingMP<psimple,tker,sim2d> <<<sgridf,bsfluid,phasecount*sizeof(StPhaseShiftData)>>> (npf,npb,hdiv,nc,cellfluid,begincell,cellzero,dcell,posxy,posz,pospress,velrhop,code,idp,ace,surf,phasedata,tshifting,shiftcoef,shiftfs,shiftpos,shiftdetect,dt);
    }
}

void RunShifting_MP(bool psimple,TpKernel tkernel,TpCellMode cellmode
  ,unsigned bsbound,unsigned bsfluid
  ,unsigned np,unsigned npb,unsigned npbok,tuint3 ncells
  ,const int2 *begincell,tuint3 cellmin,const unsigned *dcell
  ,const double2 *posxy,const double *posz,const float4 *pospress
  ,const float4 *velrhop,const word *code,const unsigned *idp,float3 *ace
  ,tsymatrix3f *surf,StPhaseData *phasedata,TpShifting tshifting,float shiftcoef,float shiftfs
  ,float3 *shiftpos,const float *shiftdetect,const unsigned phasecount
  ,bool simulate2d,JBlockSizeAuto *bsauto,double dt){

  if(tkernel==KERNEL_Wendland){    const TpKernel tker=KERNEL_Wendland;
    if(psimple){      const bool psimple=true;
	  if(simulate2d)RunShifting_MPT<psimple,tker,true>(cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ace,surf,phasedata,tshifting,shiftcoef,shiftfs,shiftpos,shiftdetect,phasecount,bsauto,dt);
	  else RunShifting_MPT<psimple,tker,false>(cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ace,surf,phasedata,tshifting,shiftcoef,shiftfs,shiftpos,shiftdetect,phasecount,bsauto,dt);
	}
	else{			  const bool psimple=false;
	  if(simulate2d)RunShifting_MPT<psimple,tker,true>(cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ace,surf,phasedata,tshifting,shiftcoef,shiftfs,shiftpos,shiftdetect,phasecount,bsauto,dt);
	  else RunShifting_MPT<psimple,tker,false>(cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ace,surf,phasedata,tshifting,shiftcoef,shiftfs,shiftpos,shiftdetect,phasecount,bsauto,dt);

	}
  }
  else if(tkernel==KERNEL_Cubic){ const TpKernel tker=KERNEL_Cubic;
    if(psimple){      const bool psimple=true;
	  if(simulate2d)RunShifting_MPT<psimple,tker,true>(cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ace,surf,phasedata,tshifting,shiftcoef,shiftfs,shiftpos,shiftdetect,phasecount,bsauto,dt);
	  else RunShifting_MPT<psimple,tker,false>(cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ace,surf,phasedata,tshifting,shiftcoef,shiftfs,shiftpos,shiftdetect,phasecount,bsauto,dt);
	}
	else{			  const bool psimple=false;
	  if(simulate2d)RunShifting_MPT<psimple,tker,true>(cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ace,surf,phasedata,tshifting,shiftcoef,shiftfs,shiftpos,shiftdetect,phasecount,bsauto,dt);
	  else RunShifting_MPT<psimple,tker,false>(cellmode,bsbound,bsfluid,np,npb,npbok,ncells,begincell,cellmin,dcell,posxy,posz,pospress,velrhop,code,idp,ace,surf,phasedata,tshifting,shiftcoef,shiftfs,shiftpos,shiftdetect,phasecount,bsauto,dt);

	}
  }
}
//�����������������������������������������������������������������������//MP


//##############################################################################
//# Kernels para interaccion DEM.
//# Kernels for DEM interaction
//##############################################################################
//------------------------------------------------------------------------------
/// Realiza la interaccion DEM de una particula con un conjunto de ellas. (Float-Float/Bound)
/// DEM interaction of a particle with a set of particles (Float-Float/Bound).
//------------------------------------------------------------------------------
template<bool psimple> __device__ void KerInteractionForcesDemBox 
  (bool boundp2,const unsigned &pini,const unsigned &pfin
  ,const float4 *demdata,float dtforce
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop,const word *code,const unsigned *idp
  ,double3 posdp1,float3 posp1,float3 velp1,word tavp1,float masstotp1,float taup1,float kfricp1,float restitup1
  ,float3 &acep1,float &demdtp1)
{
  for(int p2=pini;p2<pfin;p2++){
    const word codep2=code[p2];
    if(CODE_GetType(codep2)!=CODE_TYPE_FLUID && tavp1!=CODE_GetTypeAndValue(codep2)){
      float drx,dry,drz;
      KerGetParticlesDr<psimple> (p2,posxy,posz,pospress,posdp1,posp1,drx,dry,drz);
      const float rr2=drx*drx+dry*dry+drz*drz;
      const float rad=sqrt(rr2);

      //-Calcula valor maximo de demdt.
      //-Computes maximum value of demdt.
      float4 demdatap2=demdata[CODE_GetTypeAndValue(codep2)];
      const float nu_mass=(boundp2? masstotp1/2: masstotp1*demdatap2.x/(masstotp1+demdatap2.x)); //-Con boundary toma la propia masa del floating 1. //-With boundary takes the actual mass of floating 1.
      const float kn=4/(3*(taup1+demdatap2.y))*sqrt(CTE.dp/4);  //generalized rigidity - Lemieux 2008
      const float dvx=velp1.x-velrhop[p2].x, dvy=velp1.y-velrhop[p2].y, dvz=velp1.z-velrhop[p2].z; //vji
      const float nx=drx/rad, ny=dry/rad, nz=drz/rad; //normal_ji             
      const float vn=dvx*nx+dvy*ny+dvz*nz; //vji.nji    
      const float demvisc=0.2f/(3.21f*(pow(nu_mass/kn,0.4f)*pow(abs(vn),-0.2f))/40.f);
      if(demdtp1<demvisc)demdtp1=demvisc;

      const float over_lap=1.0f*CTE.dp-rad; //-(ri+rj)-|dij|
      if(over_lap>0.0f){ //-Contact
        //normal                    
        const float eij=(restitup1+demdatap2.w)/2;
        const float gn=-(2.0f*log(eij)*sqrt(nu_mass*kn))/(sqrt(float(PI)+log(eij)*log(eij))); //generalized damping - Cummins 2010
        //const float gn=0.08f*sqrt(nu_mass*sqrt(CTE.dp/2)/((taup1+demdatap2.y)/2)); //generalized damping - Lemieux 2008
        float rep=kn*pow(over_lap,1.5f);
        float fn=rep-gn*pow(over_lap,0.25f)*vn;                   
        acep1.x+=(fn*nx); acep1.y+=(fn*ny); acep1.z+=(fn*nz); //-Force is applied in the normal between the particles
        //tangencial
        float dvxt=dvx-vn*nx, dvyt=dvy-vn*ny, dvzt=dvz-vn*nz; //Vji_t
        float vt=sqrt(dvxt*dvxt + dvyt*dvyt + dvzt*dvzt);
        float tx=(vt!=0? dvxt/vt: 0), ty=(vt!=0? dvyt/vt: 0), tz=(vt!=0? dvzt/vt: 0); //Tang vel unit vector
        float ft_elast=2*(kn*dtforce-gn)*vt/7;   //Elastic frictional string -->  ft_elast=2*(kn*fdispl-gn*vt)/7; fdispl=dtforce*vt;
        const float kfric_ij=(kfricp1+demdatap2.z)/2;
        float ft=kfric_ij*fn*tanh(8*vt);  //Coulomb
        ft=(ft<ft_elast? ft: ft_elast);   //not above yield criteria, visco-elastic model
        acep1.x+=(ft*tx); acep1.y+=(ft*ty); acep1.z+=(ft*tz);
      }
    }
  }
}

//------------------------------------------------------------------------------
/// Realiza interaccion entre particulas. Fluid/Float-Fluid/Float or Fluid/Float-Bound
/// Incluye visco artificial/laminar y floatings normales/dem.
/// Interaction between particles. Fluid/Float-Fluid/Float or Fluid/Float-Bound.
/// Includes artificial/laminar viscosity and normal/DEM floating bodies.
//------------------------------------------------------------------------------
template<bool psimple> __global__ void KerInteractionForcesDem
  (unsigned nfloat,int hdiv,uint4 nc,unsigned cellfluid
  ,const int2 *begincell,int3 cellzero,const unsigned *dcell
  ,const unsigned *ftridp,const float4 *demdata,float dtforce
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop,const word *code,const unsigned *idp
  ,float *viscdt,float3 *ace)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle
  if(p<nfloat){
    const unsigned p1=ftridp[p];      //-N� de particula. //-NI of the particle
    if(p1!=UINT_MAX){
      float demdtp1=0;
      float3 acep1=make_float3(0,0,0);

      //-Obtiene datos basicos de particula p1.
      //-Obtains basic data of particle p1.
      double3 posdp1;
      float3 posp1,velp1;
      KerGetParticleData<psimple>(p1,posxy,posz,pospress,velrhop,velp1,posdp1,posp1);
      const word tavp1=CODE_GetTypeAndValue(code[p1]);
      float4 rdata=demdata[tavp1];
      const float masstotp1=rdata.x;
      const float taup1=rdata.y;
      const float kfricp1=rdata.z;
      const float restitup1=rdata.w;

      //-Obtiene limites de interaccion
      //-Obtains interaction limits
      int cxini,cxfin,yini,yfin,zini,zfin;
      KerGetInteractionCells(dcell[p1],hdiv,nc,cellzero,cxini,cxfin,yini,yfin,zini,zfin);

      //-Interaccion con contorno.
      //-Interaction with boundaries.
      for(int z=zini;z<zfin;z++){
        int zmod=(nc.w)*z;
        for(int y=yini;y<yfin;y++){
          int ymod=zmod+nc.x*y;
          unsigned pini,pfin=0;
          for(int x=cxini;x<cxfin;x++){
            int2 cbeg=begincell[x+ymod];
            if(cbeg.y){
              if(!pfin)pini=cbeg.x;
              pfin=cbeg.y;
            }
          }
          if(pfin)KerInteractionForcesDemBox<psimple> (true ,pini,pfin,demdata,dtforce,posxy,posz,pospress,velrhop,code,idp,posdp1,posp1,velp1,tavp1,masstotp1,taup1,kfricp1,restitup1,acep1,demdtp1);
        }
      }

      //-Interaccion con Fluidas.
      //-Interaction with fluids.
      for(int z=zini;z<zfin;z++){
        int zmod=(nc.w)*z+cellfluid; //-Le suma donde empiezan las celdas de fluido. //-The sum showing where fluid cells start
        for(int y=yini;y<yfin;y++){
          int ymod=zmod+nc.x*y;
          unsigned pini,pfin=0;
          for(int x=cxini;x<cxfin;x++){
            int2 cbeg=begincell[x+ymod];
            if(cbeg.y){
              if(!pfin)pini=cbeg.x;
              pfin=cbeg.y;
            }
          }
          if(pfin)KerInteractionForcesDemBox<psimple> (false,pini,pfin,demdata,dtforce,posxy,posz,pospress,velrhop,code,idp,posdp1,posp1,velp1,tavp1,masstotp1,taup1,kfricp1,restitup1,acep1,demdtp1);
        }
      }
      //-Almacena resultados.
      //-Stores results.
      if(acep1.x || acep1.y || acep1.z || demdtp1){
        float3 r=ace[p1]; r.x+=acep1.x; r.y+=acep1.y; r.z+=acep1.z; ace[p1]=r;
        if(viscdt[p1]<demdtp1)viscdt[p1]=demdtp1;
      }
    }
  }
}

//==============================================================================
/// Collects kernel information.
//==============================================================================
template<bool psimple> void Interaction_ForcesDemT_KerInfo(StKerInfo *kerinfo)
{
#if CUDART_VERSION >= 6050
  {
    typedef void (*fun_ptr)(unsigned,int,uint4,unsigned,const int2*,int3,const unsigned*,const unsigned*,const float4*,float,const double2*,const double*,const float4*,const float4*,const word*,const unsigned*,float*,float3*);
    fun_ptr ptr=&KerInteractionForcesDem<psimple>;
    int qblocksize=0,mingridsize=0;
    cudaOccupancyMaxPotentialBlockSize(&mingridsize,&qblocksize,(void*)ptr,0,0);
    struct cudaFuncAttributes attr;
    cudaFuncGetAttributes(&attr,(void*)ptr);
    kerinfo->forcesdem_bs=qblocksize;
    kerinfo->forcesdem_rg=attr.numRegs;
    kerinfo->forcesdem_bsmax=attr.maxThreadsPerBlock;
    //printf(">> KerInteractionForcesDem  blocksize:%u (%u)\n",qblocksize,0);
  }
  CheckErrorCuda("Error collecting kernel information.");
#endif
}

//==============================================================================
/// Interaccion para el calculo de fuerzas.
/// Interaction for the force computation.
//==============================================================================
template<bool psimple> void Interaction_ForcesDemT
  (TpCellMode cellmode,unsigned bsize
  ,unsigned nfloat,tuint3 ncells,const int2 *begincell,tuint3 cellmin,const unsigned *dcell
  ,const unsigned *ftridp,const float4 *demdata,float dtforce
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop
  ,const word *code,const unsigned *idp,float *viscdt,float3 *ace,StKerInfo *kerinfo)
{
  //-Collects kernel information.
  if(kerinfo)Interaction_ForcesDemT_KerInfo<psimple>(kerinfo);
  else{
    const int hdiv=(cellmode==CELLMODE_H? 2: 1);
    const uint4 nc=make_uint4(ncells.x,ncells.y,ncells.z,ncells.x*ncells.y);
    const unsigned cellfluid=nc.w*nc.z+1;
    const int3 cellzero=make_int3(cellmin.x,cellmin.y,cellmin.z);
    //-Interaccion Fluid-Fluid & Fluid-Bound
    //-Interaction Fluid-Fluid & Fluid-Bound
    if(nfloat){
      dim3 sgrid=GetGridSize(nfloat,bsize);
      KerInteractionForcesDem<psimple> <<<sgrid,bsize>>> (nfloat,hdiv,nc,cellfluid,begincell,cellzero,dcell,ftridp,demdata,dtforce,posxy,posz,pospress,velrhop,code,idp,viscdt,ace);
    }
  }
}
//==============================================================================
void Interaction_ForcesDem(bool psimple,TpCellMode cellmode,unsigned bsize
  ,unsigned nfloat,tuint3 ncells,const int2 *begincell,tuint3 cellmin,const unsigned *dcell
  ,const unsigned *ftridp,const float4 *demdata,float dtforce
  ,const double2 *posxy,const double *posz,const float4 *pospress,const float4 *velrhop
  ,const word *code,const unsigned *idp,float *viscdt,float3 *ace,StKerInfo *kerinfo)
{
  if(psimple)Interaction_ForcesDemT<true>  (cellmode,bsize,nfloat,ncells,begincell,cellmin,dcell,ftridp,demdata,dtforce,posxy,posz,pospress,velrhop,code,idp,viscdt,ace,kerinfo);
  else       Interaction_ForcesDemT<false> (cellmode,bsize,nfloat,ncells,begincell,cellmin,dcell,ftridp,demdata,dtforce,posxy,posz,pospress,velrhop,code,idp,viscdt,ace,kerinfo);
}


//##############################################################################
//# Kernels para Laminar+SPS.
//##############################################################################
//------------------------------------------------------------------------------
/// Computes sub-particle stress tensor (Tau) for SPS turbulence model.
//------------------------------------------------------------------------------
__global__ void KerComputeSpsTau(unsigned n,unsigned pini,float smag,float blin
  ,const float4 *velrhop,const float2 *gradvelff,float2 *tauff)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; 
  if(p<n){
    const unsigned p1=p+pini;
    float2 rr=gradvelff[p1*3];   const float grad_xx=rr.x,grad_xy=rr.y;
           rr=gradvelff[p1*3+1]; const float grad_xz=rr.x,grad_yy=rr.y;
           rr=gradvelff[p1*3+2]; const float grad_yz=rr.x,grad_zz=rr.y;
    const float pow1=grad_xx*grad_xx + grad_yy*grad_yy + grad_zz*grad_zz;
    const float prr= grad_xy*grad_xy + grad_xz*grad_xz + grad_yz*grad_yz + pow1+pow1;
    const float visc_sps=smag*sqrt(prr);
    const float div_u=grad_xx+grad_yy+grad_zz;
    const float sps_k=(2.0f/3.0f)*visc_sps*div_u;
    const float sps_blin=blin*prr;
    const float sumsps=-(sps_k+sps_blin);
    const float twovisc_sps=(visc_sps+visc_sps);
    float one_rho2=1.0f/velrhop[p1].w;
    //-Calcula nuevos valores de tau[].
    //-Computes new values of tau[].
    const float tau_xx=one_rho2*(twovisc_sps*grad_xx +sumsps);
    const float tau_xy=one_rho2*(visc_sps   *grad_xy);
    tauff[p1*3]=make_float2(tau_xx,tau_xy);
    const float tau_xz=one_rho2*(visc_sps   *grad_xz);
    const float tau_yy=one_rho2*(twovisc_sps*grad_yy +sumsps);
    tauff[p1*3+1]=make_float2(tau_xz,tau_yy);
    const float tau_yz=one_rho2*(visc_sps   *grad_yz);
    const float tau_zz=one_rho2*(twovisc_sps*grad_zz +sumsps);
    tauff[p1*3+2]=make_float2(tau_yz,tau_zz);
  }
}

//==============================================================================
/// Computes sub-particle stress tensor (Tau) for SPS turbulence model.
//==============================================================================
void ComputeSpsTau(unsigned np,unsigned npb,float smag,float blin
  ,const float4 *velrhop,const tsymatrix3f *gradvelg,tsymatrix3f *tau)
{
  const unsigned npf=np-npb;
  if(npf){
    dim3 sgridf=GetGridSize(npf,SPHBSIZE);
    KerComputeSpsTau <<<sgridf,SPHBSIZE>>> (npf,npb,smag,blin,velrhop,(const float2*)gradvelg,(float2*)tau);
  }
}


//##############################################################################
//# Kernels para Delta-SPH.
//# Kernels for Delta-SPH.
//##############################################################################
//------------------------------------------------------------------------------
/// A�ade valor de delta[] a ar[] siempre que no sea FLT_MAX.
/// Adds value of delta[] to ar[] provided it is not FLT_MAX.
//------------------------------------------------------------------------------
__global__ void KerAddDelta(unsigned n,const float *delta,float *ar)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle.
  if(p<n){
    float rdelta=delta[p];
    if(rdelta!=FLT_MAX)ar[p]+=rdelta;
  }
}

//==============================================================================
/// A�ade valor de delta[] a ar[] siempre que no sea FLT_MAX.
/// Adds value of delta[] to ar[] provided it is not FLT_MAX.
//==============================================================================
void AddDelta(unsigned n,const float *delta,float *ar){
  if(n){
    dim3 sgrid=GetGridSize(n,SPHBSIZE);
    KerAddDelta <<<sgrid,SPHBSIZE>>> (n,delta,ar);
  }
}


//##############################################################################
//# Kernels para Shifting.
//# Shifting kernels. (only for single-phase simulations)
//##############################################################################
//------------------------------------------------------------------------------
/// Calcula Shifting final para posicion de particulas.
/// Computes final shifting for the particle position. (only for single-phase simulations)
//------------------------------------------------------------------------------
__global__ void KerRunShifting(unsigned n,unsigned pini,double dt
  ,float shiftcoef,float shifttfs,double coeftfs
  ,const float4 *velrhop,const float *shiftdetect,float3 *shiftpos)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle.
  if(p<n){
    const unsigned p1=p+pini;
    const float4 rvel=velrhop[p1];
    const double vx=double(rvel.x);
    const double vy=double(rvel.y);
    const double vz=double(rvel.z);
    double umagn=double(shiftcoef)*double(CTE.h)*sqrt(vx*vx+vy*vy+vz*vz)*dt;
    if(shiftdetect){
      const float rdetect=shiftdetect[p1];
      if(rdetect<shifttfs)umagn=0;
      else umagn*=(double(rdetect)-shifttfs)/coeftfs;
    }
    float3 rshiftpos=shiftpos[p1];
    if(rshiftpos.x==FLT_MAX)umagn=0; //-Anula shifting por proximidad del contorno. //-Cancels shifting close to the boundaries.
    rshiftpos.x=float(double(rshiftpos.x)*umagn);
    rshiftpos.y=float(double(rshiftpos.y)*umagn);
    rshiftpos.z=float(double(rshiftpos.z)*umagn);
    shiftpos[p1]=rshiftpos;
  }
}

//==============================================================================
/// Calcula Shifting final para posicion de particulas.
/// Computes final shifting for the particle position. (only for single-phase simulations)
//==============================================================================
void RunShifting(unsigned np,unsigned npb,double dt
  ,double shiftcoef,float shifttfs,double coeftfs
  ,const float4 *velrhop,const float *shiftdetect,float3 *shiftpos)
{
  const unsigned n=np-npb;
  if(n){
    dim3 sgrid=GetGridSize(n,SPHBSIZE);
    KerRunShifting <<<sgrid,SPHBSIZE>>> (n,npb,dt,shiftcoef,shifttfs,coeftfs,velrhop,shiftdetect,shiftpos);
  }
}


//##############################################################################
//# Kernels para ComputeStep (vel & rhop)
//# Kernels for ComputeStep (vel & rhop)
//##############################################################################
//------------------------------------------------------------------------------
/// Calcula nuevos valores de  Pos, Check, Vel y Rhop (usando Verlet).
/// El valor de Vel para bound siempre se pone a cero.
/// Computes new values for Pos, Check, Vel and Ros (using Verlet).
/// The value of Vel always set to be reset.
//------------------------------------------------------------------------------
template<bool floating,bool shift> __global__ void KerComputeStepVerlet
  (unsigned n,unsigned npb,float rhopoutmin,float rhopoutmax
  ,const float4 *velrhop1,const float4 *velrhop2
  ,const float *ar,const float3 *ace,const float3 *shiftpos
  ,double dt,double dt205,double dt2
  ,double2 *movxy,double *movz,word *code,float4 *velrhopnew)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle.
  if(p<n){
    if(p<npb){//-Particulas: Fixed & Moving //-Particles: Fixed & Moving
      float rrhop=float(double(velrhop2[p].w)+dt2*ar[p]);
      rrhop=(rrhop<CTE.rhopzero? CTE.rhopzero: rrhop); //-Evita q las boundary absorvan a las fluidas. //-To prevent absorption of fluid particles by boundaries.
      velrhopnew[p]=make_float4(0,0,0,rrhop);
    }
    else{ //-Particulas: Floating & Fluid //-Particles: Floating & Fluid
      //-Actualiza densidad.
      //-Updates density.
      float4 rvelrhop2=velrhop2[p];
      rvelrhop2.w=float(double(rvelrhop2.w)+dt2*ar[p]);
      float4 rvel1=velrhop1[p];
      if(!floating || CODE_GetType(code[p])==CODE_TYPE_FLUID){//-Particulas: Fluid //-Particles: Fluid
        //-Comprueba limites de rhop.
        //-Checks rhop limits.
        if(rvelrhop2.w<rhopoutmin||rvelrhop2.w>rhopoutmax){//-Solo marca como excluidas las normales (no periodicas). //-Only brands as excluded normal particles (not periodic)
          const word rcode=code[p];
          if(CODE_GetSpecialValue(rcode)==CODE_NORMAL)code[p]=CODE_SetOutRhop(rcode);
        }
        //-Calcula y graba desplazamiento de posicion.
        //-Comutes and stores position displacement.
        const float3 race=ace[p];
        double dx=double(rvel1.x)*dt + double(race.x)*dt205;
        double dy=double(rvel1.y)*dt + double(race.y)*dt205;
        double dz=double(rvel1.z)*dt + double(race.z)*dt205;
        if(shift){
          const float3 rshiftpos=shiftpos[p];
          dx+=double(rshiftpos.x);
          dy+=double(rshiftpos.y);
          dz+=double(rshiftpos.z);
        }
        movxy[p]=make_double2(dx,dy);
        movz[p]=dz;
        //-Actualiza velocidad.
        //-Updates velocity.
        rvelrhop2.x=float(double(rvelrhop2.x)+double(race.x)*dt2);
        rvelrhop2.y=float(double(rvelrhop2.y)+double(race.y)*dt2);
        rvelrhop2.z=float(double(rvelrhop2.z)+double(race.z)*dt2);
        velrhopnew[p]=rvelrhop2;
      }
      else{//-Particulas: Floating //-Particles: Floating.
        rvel1.w=(rvelrhop2.w<CTE.rhopzero? CTE.rhopzero: rvelrhop2.w); //-Evita q las floating absorvan a las fluidas. //-To prevent absorption of fluid particles by boundaries.
        velrhopnew[p]=rvel1;
      }
    }
  }
}

//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Computes new values for Pos, Code, Vel and Rhop (using Verlet).
/// The value of Vel always set to be reset. -��//MP
//------------------------------------------------------------------------------
template<bool floating,bool shift> __global__ void KerComputeStepVerletMP
  (unsigned n,unsigned npb,float rhopoutmin,float rhopoutmax
  ,const float4 *velrhop1,const float4 *velrhop2
  ,const float *ar,const float3 *ace,const float3 *shiftpos
  ,double dt,double dt205,double dt2
  ,double2 *movxy,double *movz,word *code,float4 *velrhopnew
  ,StPhaseData *phasedata)
{
  //-Shared memory for storing material properties
  extern volatile __shared__ StPhaseBoundData bounddata[];
  if(threadIdx.x==0){ //only executed by thread 0
	  for(unsigned i=0; i<CTE.phasecount; i++){
		  bounddata[i].MkValue=phasedata[i].MkValue;
		  bounddata[i].PhaseMass=phasedata[i].PhaseRhop0;
		  bounddata[i].PhaseType=phasedata[i].PhaseType;
	  }
  }
  __syncthreads();
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle.
  if(p<n){
	float rhop0;
	for(unsigned iphase=0; iphase<CTE.phasecount; iphase++){ //different mass for each for each material as defined in the xml
		if(CODE_GetTypeAndValue(code[p])==bounddata[iphase].MkValue){
			rhop0=bounddata[iphase].PhaseMass;
			break;
		}
	}
    if(p<npb){//-Particulas: Fixed & Moving //-Particles: Fixed & Moving
      float rrhop=float(double(velrhop2[p].w)+dt2*ar[p]);
      rrhop=(rrhop<rhop0? rhop0: rrhop); //-Evita q las boundary absorvan a las fluidas. //-To prevent absorption of fluid particles by boundaries.
      velrhopnew[p]=make_float4(0,0,0,rrhop);
    }
    else{ //-Particulas: Floating & Fluid //-Particles: Floating & Fluid
      //-Actualiza densidad.
      //-Updates density.
      float4 rvelrhop2=velrhop2[p];
      rvelrhop2.w=float(double(rvelrhop2.w)+dt2*ar[p]);
      float4 rvel1=velrhop1[p];
      if(!floating || CODE_GetType(code[p])==CODE_TYPE_FLUID){//-Particulas: Fluid //-Particles: Fluid
        //-Comprueba limites de rhop.
        //-Checks rhop limits.
        if(rvelrhop2.w<rhopoutmin||rvelrhop2.w>rhopoutmax){//-Solo marca como excluidas las normales (no periodicas). //-Only brands as excluded normal particles (not periodic)
          const word rcode=code[p];
          if(CODE_GetSpecialValue(rcode)==CODE_NORMAL)code[p]=CODE_SetOutRhop(rcode);
        }
        //-Calcula y graba desplazamiento de posicion.
        //-Comutes and stores position displacement.
        const float3 race=ace[p];
        double dx=double(rvel1.x)*dt + double(race.x)*dt205;
        double dy=double(rvel1.y)*dt + double(race.y)*dt205;
        double dz=double(rvel1.z)*dt + double(race.z)*dt205;
        if(shift){
          const float3 rshiftpos=shiftpos[p];
          dx+=double(rshiftpos.x);
          dy+=double(rshiftpos.y);
          dz+=double(rshiftpos.z);
        }
        movxy[p]=make_double2(dx,dy);
        movz[p]=dz;
        //-Actualiza velocidad.
        //-Updates velocity.
        rvelrhop2.x=float(double(rvelrhop2.x)+double(race.x)*dt2);
        rvelrhop2.y=float(double(rvelrhop2.y)+double(race.y)*dt2);
        rvelrhop2.z=float(double(rvelrhop2.z)+double(race.z)*dt2);
        velrhopnew[p]=rvelrhop2;
      }
      else{//-Particulas: Floating //-Particles: Floating.
        rvel1.w=(rvelrhop2.w<rhop0? rhop0: rvelrhop2.w); //-Evita q las floating absorvan a las fluidas. //-To prevent absorption of fluid particles by boundaries.
        velrhopnew[p]=rvel1;
      }
    }
  }
}
//�����������������������������������������������������������������������//MP

//==============================================================================
/// Actualizacion de particulas segun fuerzas y dt usando Verlet.
/// Updates particles according to forces and dt using Verlet. 
//==============================================================================
void ComputeStepVerlet(bool floating,bool shift,unsigned np,unsigned npb
  ,const float4 *velrhop1,const float4 *velrhop2
  ,const float *ar,const float3 *ace,const float3 *shiftpos
  ,double dt,double dt2,float rhopoutmin,float rhopoutmax
  ,word *code,double2 *movxy,double *movz,float4 *velrhopnew)
{
  double dt205=(0.5*dt*dt);
  if(np){
    dim3 sgrid=GetGridSize(np,SPHBSIZE);
    if(shift){    const bool shift=true;
      if(floating)KerComputeStepVerlet<true,shift>  <<<sgrid,SPHBSIZE>>> (np,npb,rhopoutmin,rhopoutmax,velrhop1,velrhop2,ar,ace,shiftpos,dt,dt205,dt2,movxy,movz,code,velrhopnew);
      else        KerComputeStepVerlet<false,shift> <<<sgrid,SPHBSIZE>>> (np,npb,rhopoutmin,rhopoutmax,velrhop1,velrhop2,ar,ace,shiftpos,dt,dt205,dt2,movxy,movz,code,velrhopnew);
    }else{        const bool shift=false;
      if(floating)KerComputeStepVerlet<true,shift>  <<<sgrid,SPHBSIZE>>> (np,npb,rhopoutmin,rhopoutmax,velrhop1,velrhop2,ar,ace,shiftpos,dt,dt205,dt2,movxy,movz,code,velrhopnew);
      else        KerComputeStepVerlet<false,shift> <<<sgrid,SPHBSIZE>>> (np,npb,rhopoutmin,rhopoutmax,velrhop1,velrhop2,ar,ace,shiftpos,dt,dt205,dt2,movxy,movz,code,velrhopnew);
    }
  }
}

//�����������������������������������������������������������������������//MP
//==============================================================================
/// Updates particles according to forces and dt using Verlet. -��//MP
//==============================================================================
void ComputeStepVerletMP(bool floating,bool shift,unsigned np,unsigned npb
  ,const float4 *velrhop1,const float4 *velrhop2
  ,const float *ar,const float3 *ace,const float3 *shiftpos
  ,double dt,double dt2,float rhopoutmin,float rhopoutmax
  ,word *code,double2 *movxy,double *movz,float4 *velrhopnew
  ,const unsigned phasecount,StPhaseData *phasedata)
{
  double dt205=(0.5*dt*dt);
  if(np){
    dim3 sgrid=GetGridSize(np,SPHBSIZE);
    if(shift){    const bool shift=true;
      if(floating)KerComputeStepVerletMP<true,shift>  <<<sgrid,SPHBSIZE,phasecount*sizeof(StPhaseBoundData)>>> (np,npb,rhopoutmin,rhopoutmax,velrhop1,velrhop2,ar,ace,shiftpos,dt,dt205,dt2,movxy,movz,code,velrhopnew,phasedata);
      else        KerComputeStepVerletMP<false,shift> <<<sgrid,SPHBSIZE,phasecount*sizeof(StPhaseBoundData)>>> (np,npb,rhopoutmin,rhopoutmax,velrhop1,velrhop2,ar,ace,shiftpos,dt,dt205,dt2,movxy,movz,code,velrhopnew,phasedata);
    }else{        const bool shift=false;
      if(floating)KerComputeStepVerletMP<true,shift>  <<<sgrid,SPHBSIZE,phasecount*sizeof(StPhaseBoundData)>>> (np,npb,rhopoutmin,rhopoutmax,velrhop1,velrhop2,ar,ace,shiftpos,dt,dt205,dt2,movxy,movz,code,velrhopnew,phasedata);
      else        KerComputeStepVerletMP<false,shift> <<<sgrid,SPHBSIZE,phasecount*sizeof(StPhaseBoundData)>>> (np,npb,rhopoutmin,rhopoutmax,velrhop1,velrhop2,ar,ace,shiftpos,dt,dt205,dt2,movxy,movz,code,velrhopnew,phasedata);
    }
  }
}
//�����������������������������������������������������������������������//MP

//------------------------------------------------------------------------------
/// Calcula los nuevos valores de Pos, Vel y Rhop (usando para Symplectic-Predictor)
/// Computes new values for Pos, Check, Vel and Ros (used with Symplectic-Predictor).
//------------------------------------------------------------------------------
template<bool floating,bool shift> __global__ void KerComputeStepSymplecticPre
  (unsigned n,unsigned npb
  ,const float4 *velrhoppre,const float *ar,const float3 *ace,const float3 *shiftpos
  ,double dtm,float rhopoutmin,float rhopoutmax
  ,word *code,double2 *movxy,double *movz,float4 *velrhop)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle.
  if(p<n){
    if(p<npb){//-Particulas: Fixed & Moving //-Particles: Fixed & Moving
      float4 rvelrhop=velrhoppre[p];
      rvelrhop.w=float(double(rvelrhop.w)+dtm*ar[p]);
      rvelrhop.w=(rvelrhop.w<CTE.rhopzero? CTE.rhopzero: rvelrhop.w); //-Evita q las boundary absorvan a las fluidas.  //-To prevent absorption of fluid particles by boundaries.
      velrhop[p]=rvelrhop;
    }
    else{ //-Particulas: Floating & Fluid //-Particles: Floating & Fluid
      //-Actualiza densidad.
      //-Updates density.
      float4 rvelrhop=velrhoppre[p];
      rvelrhop.w=float(double(rvelrhop.w)+dtm*ar[p]);
      if(!floating || CODE_GetType(code[p])==CODE_TYPE_FLUID){//-Particulas: Fluid //-Particles: Fluid
        //-Comprueba limites de rhop.
        //-Checks rhop limits.
        if(rvelrhop.w<rhopoutmin||rvelrhop.w>rhopoutmax){//-Solo marca como excluidas las normales (no periodicas).  //-Only brands as excluded normal particles (not periodic)
          const word rcode=code[p];
          if(CODE_GetSpecialValue(rcode)==CODE_NORMAL)code[p]=CODE_SetOutRhop(rcode);
        }
        //-Calcula y graba desplazamiento de posicion.
        //-Computes and stores position displacement.
        double dx=double(rvelrhop.x)*dtm;
        double dy=double(rvelrhop.y)*dtm;
        double dz=double(rvelrhop.z)*dtm;
        if(shift){
          const float3 rshiftpos=shiftpos[p];
          dx+=double(rshiftpos.x);
          dy+=double(rshiftpos.y);
          dz+=double(rshiftpos.z);
        }
        movxy[p]=make_double2(dx,dy);
        movz[p]=dz;
        //-Actualiza velocidad.
        //-Updates velocity.
        const float3 race=ace[p];
        rvelrhop.x=float(double(rvelrhop.x)+double(race.x)*dtm);
        rvelrhop.y=float(double(rvelrhop.y)+double(race.y)*dtm);
        rvelrhop.z=float(double(rvelrhop.z)+double(race.z)*dtm);
      }
      else{//-Particulas: Floating /-Particles: Floating
        rvelrhop.w=(rvelrhop.w<CTE.rhopzero? CTE.rhopzero: rvelrhop.w); //-Evita q las floating absorvan a las fluidas.  //-To prevent absorption of fluid particles by boundaries.
      }
      //-Graba nueva velocidad y densidad.
      //-Stores new velocity and density.
      velrhop[p]=rvelrhop;
    }
  }
}

//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Calcula los nuevos valores de Pos, Vel y Rhop (usando para Symplectic-Predictor)
/// Computes new values for Pos, Code, Vel and Ros (used with Symplectic-Predictor). -��//MP
//------------------------------------------------------------------------------
template<bool floating,bool shift> __global__ void KerComputeStepSymplecticPreMP
  (unsigned n,unsigned npb
  ,const float4 *velrhoppre,const float *ar,const float3 *ace,const float3 *shiftpos
  ,double dtm,float rhopoutmin,float rhopoutmax
  ,word *code,double2 *movxy,double *movz,float4 *velrhop
  ,StPhaseData *phasedata)
{
  //-Shared memory for storing material properties
  extern volatile __shared__ StPhaseBoundData bounddata[];
  if(threadIdx.x==0){ //only executed by thread 0
	  for(unsigned i=0; i<CTE.phasecount; i++){
		  bounddata[i].MkValue=phasedata[i].MkValue;
		  bounddata[i].PhaseMass=phasedata[i].PhaseRhop0;
		  bounddata[i].PhaseType=phasedata[i].PhaseType;
	  }
  }
  __syncthreads();
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle.
  if(p<n){
	float rhop0;
	for(unsigned iphase=0; iphase<CTE.phasecount; iphase++){ //different mass for each for each material as defined in the xml
		if(CODE_GetTypeAndValue(code[p])==bounddata[iphase].MkValue){
			rhop0=bounddata[iphase].PhaseMass;
			break;
		}
	}
    if(p<npb){//-Particulas: Fixed & Moving //-Particles: Fixed & Moving
      float4 rvelrhop=velrhoppre[p];
      rvelrhop.w=float(double(rvelrhop.w)+dtm*ar[p]);
      rvelrhop.w=(rvelrhop.w<rhop0? rhop0: rvelrhop.w); //-Evita q las boundary absorvan a las fluidas.  //-To prevent absorption of fluid particles by boundaries.
      velrhop[p]=rvelrhop;
    }
    else{ //-Particulas: Floating & Fluid //-Particles: Floating & Fluid
      //-Actualiza densidad.
      //-Updates density.
      float4 rvelrhop=velrhoppre[p];
      rvelrhop.w=float(double(rvelrhop.w)+dtm*ar[p]);
      if(!floating || CODE_GetType(code[p])==CODE_TYPE_FLUID){//-Particulas: Fluid //-Particles: Fluid
        //-Comprueba limites de rhop.
        //-Checks rhop limits.
        if(rvelrhop.w<rhopoutmin||rvelrhop.w>rhopoutmax){//-Solo marca como excluidas las normales (no periodicas).  //-Only brands as excluded normal particles (not periodic)
          const word rcode=code[p];
          if(CODE_GetSpecialValue(rcode)==CODE_NORMAL)code[p]=CODE_SetOutRhop(rcode);
        }
        //-Calcula y graba desplazamiento de posicion.
        //-Computes and stores position displacement.
        double dx=double(rvelrhop.x)*dtm;
        double dy=double(rvelrhop.y)*dtm;
        double dz=double(rvelrhop.z)*dtm;
        //if(shift){ //Removed shifting from predictor step
        //  const float3 rshiftpos=shiftpos[p];
        //  dx+=double(rshiftpos.x);
        //  dy+=double(rshiftpos.y);
        //  dz+=double(rshiftpos.z);
        //}
        movxy[p]=make_double2(dx,dy);
        movz[p]=dz;
        //-Actualiza velocidad.
        //-Updates velocity.
        const float3 race=ace[p];
        rvelrhop.x=float(double(rvelrhop.x)+double(race.x)*dtm);
        rvelrhop.y=float(double(rvelrhop.y)+double(race.y)*dtm);
        rvelrhop.z=float(double(rvelrhop.z)+double(race.z)*dtm);
      }
      else{//-Particulas: Floating /-Particles: Floating
        rvelrhop.w=(rvelrhop.w<rhop0? rhop0: rvelrhop.w); //-Evita q las floating absorvan a las fluidas.  //-To prevent absorption of fluid particles by boundaries.
      }
      //-Graba nueva velocidad y densidad.
      //-Stores new velocity and density.
      velrhop[p]=rvelrhop;
    }
  }
}
//�����������������������������������������������������������������������//MP

//==============================================================================
/// Actualizacion de particulas usando Symplectic-Predictor.
/// Updates particles using Symplectic-Predictor.
//==============================================================================   
void ComputeStepSymplecticPre(bool floating,bool shift,unsigned np,unsigned npb
  ,const float4 *velrhoppre,const float *ar,const float3 *ace,const float3 *shiftpos
  ,double dtm,float rhopoutmin,float rhopoutmax
  ,word *code,double2 *movxy,double *movz,float4 *velrhop)
{
  if(np){
    dim3 sgrid=GetGridSize(np,SPHBSIZE);
    if(shift){    const bool shift=true;
      if(floating)KerComputeStepSymplecticPre<true,shift>  <<<sgrid,SPHBSIZE>>> (np,npb,velrhoppre,ar,ace,shiftpos,dtm,rhopoutmin,rhopoutmax,code,movxy,movz,velrhop);
      else        KerComputeStepSymplecticPre<false,shift> <<<sgrid,SPHBSIZE>>> (np,npb,velrhoppre,ar,ace,shiftpos,dtm,rhopoutmin,rhopoutmax,code,movxy,movz,velrhop);
    }else{        const bool shift=false;
      if(floating)KerComputeStepSymplecticPre<true,shift>  <<<sgrid,SPHBSIZE>>> (np,npb,velrhoppre,ar,ace,shiftpos,dtm,rhopoutmin,rhopoutmax,code,movxy,movz,velrhop);
      else        KerComputeStepSymplecticPre<false,shift> <<<sgrid,SPHBSIZE>>> (np,npb,velrhoppre,ar,ace,shiftpos,dtm,rhopoutmin,rhopoutmax,code,movxy,movz,velrhop);
    }
  }
}

//�����������������������������������������������������������������������//MP
//==============================================================================
/// Actualizacion de particulas usando Symplectic-Predictor.
/// Updates particles using Symplectic-Predictor. -��//MP
//==============================================================================   
void ComputeStepSymplecticPreMP(bool floating,bool shift,unsigned np,unsigned npb
  ,const float4 *velrhoppre,const float *ar,const float3 *ace,const float3 *shiftpos
  ,double dtm,float rhopoutmin,float rhopoutmax
  ,word *code,double2 *movxy,double *movz,float4 *velrhop
  ,const unsigned phasecount,StPhaseData *phasedata)
{
  if(np){
    dim3 sgrid=GetGridSize(np,SPHBSIZE);
    if(shift){    const bool shift=true;
      if(floating)KerComputeStepSymplecticPreMP<true,shift>  <<<sgrid,SPHBSIZE,phasecount*sizeof(StPhaseBoundData)>>> (np,npb,velrhoppre,ar,ace,shiftpos,dtm,rhopoutmin,rhopoutmax,code,movxy,movz,velrhop,phasedata);
      else        KerComputeStepSymplecticPreMP<false,shift> <<<sgrid,SPHBSIZE,phasecount*sizeof(StPhaseBoundData)>>> (np,npb,velrhoppre,ar,ace,shiftpos,dtm,rhopoutmin,rhopoutmax,code,movxy,movz,velrhop,phasedata);
    }else{        const bool shift=false;
      if(floating)KerComputeStepSymplecticPreMP<true,shift>  <<<sgrid,SPHBSIZE,phasecount*sizeof(StPhaseBoundData)>>> (np,npb,velrhoppre,ar,ace,shiftpos,dtm,rhopoutmin,rhopoutmax,code,movxy,movz,velrhop,phasedata);
      else        KerComputeStepSymplecticPreMP<false,shift> <<<sgrid,SPHBSIZE,phasecount*sizeof(StPhaseBoundData)>>> (np,npb,velrhoppre,ar,ace,shiftpos,dtm,rhopoutmin,rhopoutmax,code,movxy,movz,velrhop,phasedata);
    }
  }
}
//�����������������������������������������������������������������������//MP

//------------------------------------------------------------------------------
/// Calcula los nuevos valores de Pos, Vel y Rhop (usandopara Symplectic-Corrector)
/// Pone vel de contorno a cero.
/// Computes new values for Pos, Check, Vel and Ros (using Verlet).
/// The value of Vel always set to be reset.
//------------------------------------------------------------------------------
template<bool floating,bool shift> __global__ void KerComputeStepSymplecticCor
  (unsigned n,unsigned npb
  ,const float4 *velrhoppre,const float *ar,const float3 *ace,const float3 *shiftpos
  ,double dtm,double dt,float rhopoutmin,float rhopoutmax
  ,word *code,double2 *movxy,double *movz,float4 *velrhop)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle.
  if(p<n){
    if(p<npb){//-Particulas: Fixed & Moving //-Particles: Fixed & Moving
      double epsilon_rdot=(-double(ar[p])/double(velrhop[p].w))*dt;
      float rrhop=float(double(velrhoppre[p].w) * (2.-epsilon_rdot)/(2.+epsilon_rdot));
      rrhop=(rrhop<CTE.rhopzero? CTE.rhopzero: rrhop); //-Evita q las boundary absorvan a las fluidas. //-To prevent absorption of fluid particles by boundaries.
      velrhop[p]=make_float4(0,0,0,rrhop);
    }
    else{ //-Particulas: Floating & Fluid //-Particles: Floating & Fluid
      //-Actualiza densidad.
        //-Updates density.
      double epsilon_rdot=(-double(ar[p])/double(velrhop[p].w))*dt;
      float4 rvelrhop=velrhoppre[p];
      rvelrhop.w=float(double(rvelrhop.w) * (2.-epsilon_rdot)/(2.+epsilon_rdot));
      if(!floating || CODE_GetType(code[p])==CODE_TYPE_FLUID){//-Particulas: Fluid //-Particles: Fluid
        float4 rvelp=rvelrhop;
        //-Actualiza velocidad.
        //-Updates velocity.
        float3 race=ace[p];
        rvelrhop.x=float(double(rvelrhop.x)+double(race.x)*dt);
        rvelrhop.y=float(double(rvelrhop.y)+double(race.y)*dt);
        rvelrhop.z=float(double(rvelrhop.z)+double(race.z)*dt);
        //-Comprueba limites de rhop.
        //-Checks rhop limits.
        if(rvelrhop.w<rhopoutmin||rvelrhop.w>rhopoutmax){//-Solo marca como excluidas las normales (no periodicas). //-Only brands as excluded normal particles (not periodic)
          const word rcode=code[p];
          if(CODE_GetSpecialValue(rcode)==CODE_NORMAL)code[p]=CODE_SetOutRhop(rcode);
        }
        //-Calcula y graba desplazamiento de posicion.
        //-Computes and stores position displacement.
        double dx=(double(rvelp.x)+double(rvelrhop.x))*dtm;
        double dy=(double(rvelp.y)+double(rvelrhop.y))*dtm;
        double dz=(double(rvelp.z)+double(rvelrhop.z))*dtm;
        if(shift){
          const float3 rshiftpos=shiftpos[p];
          dx+=double(rshiftpos.x);
          dy+=double(rshiftpos.y);
          dz+=double(rshiftpos.z);
        }
        movxy[p]=make_double2(dx,dy);
        movz[p]=dz;
      }
      else{//-Particulas: Floating //-Particles: Floating
        rvelrhop.w=(rvelrhop.w<CTE.rhopzero? CTE.rhopzero: rvelrhop.w); //-Evita q las floating absorvan a las fluidas. //-To prevent absorption of fluid particles by boundaries.
      }
      //-Graba nueva velocidad y densidad.
      //-Stores new velocity and density.
      velrhop[p]=rvelrhop;
    }
  }
}

//�����������������������������������������������������������������������//MP
//------------------------------------------------------------------------------
/// Calcula los nuevos valores de Pos, Vel y Rhop (usandopara Symplectic-Corrector)
/// Pone vel de contorno a cero.
/// Computes new values for Pos, Code, Vel and Ros (using Verlet).
/// The value of Vel always set to be reset. -��//MP
//------------------------------------------------------------------------------
template<bool floating,bool shift> __global__ void KerComputeStepSymplecticCorMP
  (unsigned n,unsigned npb
  ,const float4 *velrhoppre,const float *ar,const float3 *ace,const float3 *shiftpos
  ,double dtm,double dt,float rhopoutmin,float rhopoutmax
  ,word *code,double2 *movxy,double *movz,float4 *velrhop
  ,StPhaseData *phasedata)
{
  //-Shared memory for storing material properties
  extern volatile __shared__ StPhaseBoundData bounddata[];
  if(threadIdx.x==0){ //only executed by thread 0
	  for(unsigned i=0; i<CTE.phasecount; i++){
		  bounddata[i].MkValue=phasedata[i].MkValue;
		  bounddata[i].PhaseMass=phasedata[i].PhaseRhop0;
		  bounddata[i].PhaseType=phasedata[i].PhaseType;
	  }
  }
  __syncthreads();
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle.
  if(p<n){
	float rhop0;
	for(unsigned iphase=0; iphase<CTE.phasecount; iphase++){ //different mass for each for each material as defined in the xml
		if(CODE_GetTypeAndValue(code[p])==bounddata[iphase].MkValue){
			rhop0=bounddata[iphase].PhaseMass;
			break;
		}
	}
    if(p<npb){//-Particulas: Fixed & Moving //-Particles: Fixed & Moving
      double epsilon_rdot=(-double(ar[p])/double(velrhop[p].w))*dt;
      float rrhop=float(double(velrhoppre[p].w) * (2.-epsilon_rdot)/(2.+epsilon_rdot));
      rrhop=(rrhop<rhop0? rhop0: rrhop); //-Evita q las boundary absorvan a las fluidas. //-To prevent absorption of fluid particles by boundaries.
      velrhop[p]=make_float4(0,0,0,rrhop);
    }
    else{ //-Particulas: Floating & Fluid //-Particles: Floating & Fluid
      //-Actualiza densidad.
        //-Updates density.
      double epsilon_rdot=(-double(ar[p])/double(velrhop[p].w))*dt;
      float4 rvelrhop=velrhoppre[p];
      rvelrhop.w=float(double(rvelrhop.w) * (2.-epsilon_rdot)/(2.+epsilon_rdot));
      if(!floating || CODE_GetType(code[p])==CODE_TYPE_FLUID){//-Particulas: Fluid //-Particles: Fluid
        float4 rvelp=rvelrhop;
        //-Actualiza velocidad.
        //-Updates velocity.
        float3 race=ace[p];
        rvelrhop.x=float(double(rvelrhop.x)+double(race.x)*dt);
        rvelrhop.y=float(double(rvelrhop.y)+double(race.y)*dt);
        rvelrhop.z=float(double(rvelrhop.z)+double(race.z)*dt);
        //-Comprueba limites de rhop.
        //-Checks rhop limits.
        if(rvelrhop.w<rhopoutmin||rvelrhop.w>rhopoutmax){//-Solo marca como excluidas las normales (no periodicas). //-Only brands as excluded normal particles (not periodic)
          const word rcode=code[p];
          if(CODE_GetSpecialValue(rcode)==CODE_NORMAL)code[p]=CODE_SetOutRhop(rcode);
        }
        //-Calcula y graba desplazamiento de posicion.
        //-Computes and stores position displacement.
        double dx=(double(rvelp.x)+double(rvelrhop.x))*dtm;
        double dy=(double(rvelp.y)+double(rvelrhop.y))*dtm;
        double dz=(double(rvelp.z)+double(rvelrhop.z))*dtm;
        if(shift){
          const float3 rshiftpos=shiftpos[p];
          dx+=double(rshiftpos.x);
          dy+=double(rshiftpos.y);
          dz+=double(rshiftpos.z);
        }
        movxy[p]=make_double2(dx,dy);
        movz[p]=dz;
      }
      else{//-Particulas: Floating //-Particles: Floating
        rvelrhop.w=(rvelrhop.w<rhop0? rhop0: rvelrhop.w); //-Evita q las floating absorvan a las fluidas. //-To prevent absorption of fluid particles by boundaries.
      }
      //-Graba nueva velocidad y densidad.
      //-Stores new velocity and density.
      velrhop[p]=rvelrhop;
    }
  }
}
//�����������������������������������������������������������������������//MP

//==============================================================================
// Actualizacion de particulas usando Symplectic-Corrector.
/// Updates particles using Symplectic-Corrector. -��//MP
//==============================================================================   
void ComputeStepSymplecticCor(bool floating,bool shift,unsigned np,unsigned npb
  ,const float4 *velrhoppre,const float *ar,const float3 *ace,const float3 *shiftpos
  ,double dtm,double dt,float rhopoutmin,float rhopoutmax
  ,word *code,double2 *movxy,double *movz,float4 *velrhop)
{
  if(np){
    dim3 sgrid=GetGridSize(np,SPHBSIZE);
    if(shift){    const bool shift=true;
      if(floating)KerComputeStepSymplecticCor<true,shift>  <<<sgrid,SPHBSIZE>>> (np,npb,velrhoppre,ar,ace,shiftpos,dtm,dt,rhopoutmin,rhopoutmax,code,movxy,movz,velrhop);
      else        KerComputeStepSymplecticCor<false,shift> <<<sgrid,SPHBSIZE>>> (np,npb,velrhoppre,ar,ace,shiftpos,dtm,dt,rhopoutmin,rhopoutmax,code,movxy,movz,velrhop);
    }else{        const bool shift=false;
      if(floating)KerComputeStepSymplecticCor<true,shift>  <<<sgrid,SPHBSIZE>>> (np,npb,velrhoppre,ar,ace,shiftpos,dtm,dt,rhopoutmin,rhopoutmax,code,movxy,movz,velrhop);
      else        KerComputeStepSymplecticCor<false,shift> <<<sgrid,SPHBSIZE>>> (np,npb,velrhoppre,ar,ace,shiftpos,dtm,dt,rhopoutmin,rhopoutmax,code,movxy,movz,velrhop);
    }
  }
}

//�����������������������������������������������������������������������//MP
//==============================================================================
// Actualizacion de particulas usando Symplectic-Corrector.
/// Updates particles using Symplectic-Corrector.
//==============================================================================   
void ComputeStepSymplecticCorMP(bool floating,bool shift,unsigned np,unsigned npb
  ,const float4 *velrhoppre,const float *ar,const float3 *ace,const float3 *shiftpos
  ,double dtm,double dt,float rhopoutmin,float rhopoutmax
  ,word *code,double2 *movxy,double *movz,float4 *velrhop
  ,const unsigned phasecount,StPhaseData *phasedata)
{
  if(np){
    dim3 sgrid=GetGridSize(np,SPHBSIZE);
    if(shift){    const bool shift=true;
      if(floating)KerComputeStepSymplecticCorMP<true,shift>  <<<sgrid,SPHBSIZE,phasecount*sizeof(StPhaseBoundData)>>> (np,npb,velrhoppre,ar,ace,shiftpos,dtm,dt,rhopoutmin,rhopoutmax,code,movxy,movz,velrhop,phasedata);
      else        KerComputeStepSymplecticCorMP<false,shift> <<<sgrid,SPHBSIZE,phasecount*sizeof(StPhaseBoundData)>>> (np,npb,velrhoppre,ar,ace,shiftpos,dtm,dt,rhopoutmin,rhopoutmax,code,movxy,movz,velrhop,phasedata);
    }else{        const bool shift=false;
      if(floating)KerComputeStepSymplecticCorMP<true,shift>  <<<sgrid,SPHBSIZE,phasecount*sizeof(StPhaseBoundData)>>> (np,npb,velrhoppre,ar,ace,shiftpos,dtm,dt,rhopoutmin,rhopoutmax,code,movxy,movz,velrhop,phasedata);
      else        KerComputeStepSymplecticCorMP<false,shift> <<<sgrid,SPHBSIZE,phasecount*sizeof(StPhaseBoundData)>>> (np,npb,velrhoppre,ar,ace,shiftpos,dtm,dt,rhopoutmin,rhopoutmax,code,movxy,movz,velrhop,phasedata);
    }
  }
}
//�����������������������������������������������������������������������//MP

//##############################################################################
//# Kernels para ComputeStep (position)
//# Kernels for ComputeStep (position)
//##############################################################################
//------------------------------------------------------------------------------
/// Actualiza pos, dcell y code a partir del desplazamiento indicado.
/// Code puede ser CODE_OUTRHOP pq en ComputeStepVerlet/Symplectic se evalua esto 
/// y se ejecuta antes que ComputeStepPos.
/// Comprueba los limites en funcion de maprealposmin y maprealsize esto es valido
/// para single-gpu pq domrealpos y maprealpos son iguales. Para multi-gpu seria 
/// necesario marcar las particulas q salgan del dominio sin salir del mapa.
/// Updates pos, dcell and code from the indicated displacement.
/// The code may be CODE_OUTRHOP because in ComputeStepVerlet / Symplectic this is evaluated
/// and is executed before ComputeStepPos.
/// Checks limits depending on maprealposmin and maprealsize, this is valid 
/// for single-GPU because maprealpos and domrealpos are equal. For multi-gpu it is
/// important to mark particles that leave the domain without leaving the map.
//------------------------------------------------------------------------------
template<bool periactive> __device__ void KerUpdatePos
  (double2 rxy,double rz,double movx,double movy,double movz
  ,bool outrhop,unsigned p,double2 *posxy,double *posz,unsigned *dcell,word *code)
{
  //-Comprueba validez del desplazamiento.
  //-Checks validity of displacement.
  bool outmove=(fmaxf(fabsf(float(movx)),fmaxf(fabsf(float(movy)),fabsf(float(movz))))>CTE.movlimit);
  //-Aplica desplazamiento.
  //-Applies diplacement.
  double3 rpos=make_double3(rxy.x,rxy.y,rz);
  rpos.x+=movx; rpos.y+=movy; rpos.z+=movz;
  //-Comprueba limites del dominio reales.
  //-Checks limits of real domain.
  double dx=rpos.x-CTE.maprealposminx;
  double dy=rpos.y-CTE.maprealposminy;
  double dz=rpos.z-CTE.maprealposminz;
  bool out=(dx!=dx || dy!=dy || dz!=dz || dx<0 || dy<0 || dz<0 || dx>=CTE.maprealsizex || dy>=CTE.maprealsizey || dz>=CTE.maprealsizez);
  if(periactive && out){
    bool xperi=(CTE.periactive&1),yperi=(CTE.periactive&2),zperi=(CTE.periactive&4);
    if(xperi){
      if(dx<0)                { dx-=CTE.xperincx; dy-=CTE.xperincy; dz-=CTE.xperincz; }
      if(dx>=CTE.maprealsizex){ dx+=CTE.xperincx; dy+=CTE.xperincy; dz+=CTE.xperincz; }
    }
    if(yperi){
      if(dy<0)                { dx-=CTE.yperincx; dy-=CTE.yperincy; dz-=CTE.yperincz; }
      if(dy>=CTE.maprealsizey){ dx+=CTE.yperincx; dy+=CTE.yperincy; dz+=CTE.yperincz; }
    }
    if(zperi){
      if(dz<0)                { dx-=CTE.zperincx; dy-=CTE.zperincy; dz-=CTE.zperincz; }
      if(dz>=CTE.maprealsizez){ dx+=CTE.zperincx; dy+=CTE.zperincy; dz+=CTE.zperincz; }
    }
    bool outx=!xperi && (dx<0 || dx>=CTE.maprealsizex);
    bool outy=!yperi && (dy<0 || dy>=CTE.maprealsizey);
    bool outz=!zperi && (dz<0 || dz>=CTE.maprealsizez);
    out=(outx||outy||outz);
    rpos=make_double3(dx+CTE.maprealposminx,dy+CTE.maprealposminy,dz+CTE.maprealposminz);
  }
  //-Guarda posicion actualizada.
  //-Stoes updated position.
  posxy[p]=make_double2(rpos.x,rpos.y);
  posz[p]=rpos.z;
  //-Guarda celda y check.
  //-Stores cell and checks.
  if(outrhop || outmove || out){//-Particle out. Solo las particulas normales (no periodicas) se pueden marcar como excluidas. //-Particle out. Only brands as excluded normal particles (not periodic).
    word rcode=code[p];
    if(outrhop)rcode=CODE_SetOutRhop(rcode);
    else if(out)rcode=CODE_SetOutPos(rcode);
    else rcode=CODE_SetOutMove(rcode);
    code[p]=rcode;
    dcell[p]=0xFFFFFFFF;
  }
  else{//-Particle in
    if(periactive){
      dx=rpos.x-CTE.domposminx;
      dy=rpos.y-CTE.domposminy;
      dz=rpos.z-CTE.domposminz;
    }
    unsigned cx=unsigned(dx/CTE.scell),cy=unsigned(dy/CTE.scell),cz=unsigned(dz/CTE.scell);
    dcell[p]=PC__Cell(CTE.cellcode,cx,cy,cz);
  }
}

//------------------------------------------------------------------------------
/// Devuelve la posicion corregida tras aplicar condiciones periodicas.
/// Returns the corrected position after applying periodic conditions.
//------------------------------------------------------------------------------
__device__ double3 KerUpdatePeriodicPos(double3 ps)
{
  double dx=ps.x-CTE.maprealposminx;
  double dy=ps.y-CTE.maprealposminy;
  double dz=ps.z-CTE.maprealposminz;
  const bool out=(dx!=dx || dy!=dy || dz!=dz || dx<0 || dy<0 || dz<0 || dx>=CTE.maprealsizex || dy>=CTE.maprealsizey || dz>=CTE.maprealsizez);
  //-Ajusta posicion segun condiciones periodicas y vuelve a comprobar los limites del dominio.
  //-Adjusts position according to periodic conditions and rechecks domain limits.
  if(out){
    bool xperi=(CTE.periactive&1),yperi=(CTE.periactive&2),zperi=(CTE.periactive&4);
    if(xperi){
      if(dx<0)                { dx-=CTE.xperincx; dy-=CTE.xperincy; dz-=CTE.xperincz; }
      if(dx>=CTE.maprealsizex){ dx+=CTE.xperincx; dy+=CTE.xperincy; dz+=CTE.xperincz; }
    }
    if(yperi){
      if(dy<0)                { dx-=CTE.yperincx; dy-=CTE.yperincy; dz-=CTE.yperincz; }
      if(dy>=CTE.maprealsizey){ dx+=CTE.yperincx; dy+=CTE.yperincy; dz+=CTE.yperincz; }
    }
    if(zperi){
      if(dz<0)                { dx-=CTE.zperincx; dy-=CTE.zperincy; dz-=CTE.zperincz; }
      if(dz>=CTE.maprealsizez){ dx+=CTE.zperincx; dy+=CTE.zperincy; dz+=CTE.zperincz; }
    }
    ps=make_double3(dx+CTE.maprealposminx,dy+CTE.maprealposminy,dz+CTE.maprealposminz);
  }
  return(ps);
}

//------------------------------------------------------------------------------
/// Actualizacion de posicion de particulas segun desplazamiento.
/// Updates particle position according to displacement.
//------------------------------------------------------------------------------
template<bool periactive,bool floating> __global__ void KerComputeStepPos(unsigned n,unsigned pini
  ,const double2 *movxy,const double *movz
  ,double2 *posxy,double *posz,unsigned *dcell,word *code)
{
  unsigned pt=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula
  if(pt<n){
    unsigned p=pt+pini;
    const word rcode=code[p];
    const bool outrhop=(CODE_GetSpecialValue(rcode)==CODE_OUTRHOP);
    const bool fluid=(!floating || CODE_GetType(rcode)==CODE_TYPE_FLUID);
    const bool normal=(!periactive || outrhop || CODE_GetSpecialValue(rcode)==CODE_NORMAL);
    if(normal && fluid){//-No se aplica a particulas periodicas o floating. //-Does not apply to periodic or floating particles.
      const double2 rmovxy=movxy[p];
      KerUpdatePos<periactive>(posxy[p],posz[p],rmovxy.x,rmovxy.y,movz[p],outrhop,p,posxy,posz,dcell,code);
    }
    //-En caso de floating mantiene la posicion original.
    //-In case of floating maintains the original position.
  }
}

//==============================================================================
/// Actualizacion de posicion de particulas segun desplazamiento.
/// Updates particle position according to displacement.
//==============================================================================
void ComputeStepPos(byte periactive,bool floating,unsigned np,unsigned npb
  ,const double2 *movxy,const double *movz
  ,double2 *posxy,double *posz,unsigned *dcell,word *code)
{
  const unsigned pini=npb;
  const unsigned npf=np-pini;
  if(npf){
    dim3 sgrid=GetGridSize(npf,SPHBSIZE);
    if(periactive){ const bool peri=true;
      if(floating)KerComputeStepPos<peri,true>  <<<sgrid,SPHBSIZE>>> (npf,pini,movxy,movz,posxy,posz,dcell,code);
      else        KerComputeStepPos<peri,false> <<<sgrid,SPHBSIZE>>> (npf,pini,movxy,movz,posxy,posz,dcell,code);
    }
    else{ const bool peri=false;
      if(floating)KerComputeStepPos<peri,true>  <<<sgrid,SPHBSIZE>>> (npf,pini,movxy,movz,posxy,posz,dcell,code);
      else        KerComputeStepPos<peri,false> <<<sgrid,SPHBSIZE>>> (npf,pini,movxy,movz,posxy,posz,dcell,code);
    }
  }
}

//------------------------------------------------------------------------------
/// Actualizacion de posicion de particulas segun desplazamiento.
/// Updates particle position according to displacement.
//------------------------------------------------------------------------------
template<bool periactive,bool floating> __global__ void KerComputeStepPos2(unsigned n,unsigned pini
  ,const double2 *posxypre,const double *poszpre,const double2 *movxy,const double *movz
  ,double2 *posxy,double *posz,unsigned *dcell,word *code)
{
  unsigned pt=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle
  if(pt<n){
    unsigned p=pt+pini;
    const word rcode=code[p];
    const bool outrhop=(CODE_GetSpecialValue(rcode)==CODE_OUTRHOP);
    const bool fluid=(!floating || CODE_GetType(rcode)==CODE_TYPE_FLUID);
    const bool normal=(!periactive || outrhop || CODE_GetSpecialValue(rcode)==CODE_NORMAL);
    if(normal){//-No se aplica a particulas periodicas //-Does not apply to periodic particles.
      if(fluid){//-Solo se aplica desplazamiento al fluido. //-Only applied for fluid displacement.
        const double2 rmovxy=movxy[p];
        KerUpdatePos<periactive>(posxypre[p],poszpre[p],rmovxy.x,rmovxy.y,movz[p],outrhop,p,posxy,posz,dcell,code);
      }
      else{
        posxy[p]=posxypre[p];
        posz[p]=poszpre[p];
      }
    }
  }
}

//==============================================================================
/// Actualizacion de posicion de particulas segun desplazamiento.
/// Updates particle position according to displacement.
//==============================================================================
void ComputeStepPos2(byte periactive,bool floating,unsigned np,unsigned npb
  ,const double2 *posxypre,const double *poszpre,const double2 *movxy,const double *movz
  ,double2 *posxy,double *posz,unsigned *dcell,word *code)
{
  const unsigned pini=npb;
  const unsigned npf=np-pini;
  if(npf){
    dim3 sgrid=GetGridSize(npf,SPHBSIZE);
    if(periactive){ const bool peri=true;
      if(floating)KerComputeStepPos2<peri,true>  <<<sgrid,SPHBSIZE>>> (npf,pini,posxypre,poszpre,movxy,movz,posxy,posz,dcell,code);
      else        KerComputeStepPos2<peri,false> <<<sgrid,SPHBSIZE>>> (npf,pini,posxypre,poszpre,movxy,movz,posxy,posz,dcell,code);
    }
    else{ const bool peri=false;
      if(floating)KerComputeStepPos2<peri,true>  <<<sgrid,SPHBSIZE>>> (npf,pini,posxypre,poszpre,movxy,movz,posxy,posz,dcell,code);
      else        KerComputeStepPos2<peri,false> <<<sgrid,SPHBSIZE>>> (npf,pini,posxypre,poszpre,movxy,movz,posxy,posz,dcell,code);
    }
  }
}


//##############################################################################
//# Kernels para Motion
//# Kernels for motion.
//##############################################################################
//------------------------------------------------------------------------------
/// Calcula para un rango de particulas calcula su posicion segun idp[].
/// Computes for a range of particles, their position according to idp[].
//------------------------------------------------------------------------------
__global__ void KerCalcRidp(unsigned n,unsigned ini,unsigned idini,unsigned idfin,const word *code,const unsigned *idp,unsigned *ridp)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle
  if(p<n){
    p+=ini;
    unsigned id=idp[p];
    if(idini<=id && id<idfin){
      if(CODE_GetSpecialValue(code[p])==CODE_NORMAL)ridp[id-idini]=p;
    }
  }
}
//------------------------------------------------------------------------------
__global__ void KerCalcRidp(unsigned n,unsigned ini,unsigned idini,unsigned idfin,const unsigned *idp,unsigned *ridp)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle
  if(p<n){
    p+=ini;
    const unsigned id=idp[p];
    if(idini<=id && id<idfin)ridp[id-idini]=p;
  }
}

//==============================================================================
/// Calcula posicion de particulas segun idp[]. Cuando no la encuentra es UINT_MAX.
/// Cuando periactive es False sumpone que no hay particulas duplicadas (periodicas)
/// y todas son CODE_NORMAL.
/// Calculate particle position according to idp[]. When it does not find UINT_MAX.
/// When periactive is false it means there are no duplicate particles (periodic)
/// and all are CODE_NORMAL.
//==============================================================================
void CalcRidp(bool periactive,unsigned np,unsigned pini,unsigned idini,unsigned idfin,const word *code,const unsigned *idp,unsigned *ridp){
  //-Asigna valores UINT_MAX
  //-Assigns values UINT_MAX
  const unsigned nsel=idfin-idini;
  cudaMemset(ridp,255,sizeof(unsigned)*nsel); 
  //-Calcula posicion segun id.
  //-Computes position according to id.
  if(np){
    dim3 sgrid=GetGridSize(np,SPHBSIZE);
    if(periactive)KerCalcRidp <<<sgrid,SPHBSIZE>>> (np,pini,idini,idfin,code,idp,ridp);
    else          KerCalcRidp <<<sgrid,SPHBSIZE>>> (np,pini,idini,idfin,idp,ridp);
  }
}

//------------------------------------------------------------------------------
/// Aplica un movimiento lineal a un conjunto de particulas.
/// Applies a linear movement to a set of particles.
//------------------------------------------------------------------------------
template<bool periactive> __global__ void KerMoveLinBound(unsigned n,unsigned ini,double3 mvpos,float3 mvvel
  ,const unsigned *ridpmv,double2 *posxy,double *posz,unsigned *dcell,float4 *velrhop,word *code)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle
  if(p<n){
    int pid=ridpmv[p+ini];
    if(pid>=0){
      //-Calcula desplazamiento y actualiza posicion.
      //-Computes displacement and updates position.
      KerUpdatePos<periactive>(posxy[pid],posz[pid],mvpos.x,mvpos.y,mvpos.z,false,pid,posxy,posz,dcell,code);
      //-Calcula velocidad.
      //-Computes velocity.
      velrhop[pid]=make_float4(mvvel.x,mvvel.y,mvvel.z,velrhop[pid].w);
    }
  }
}

//==============================================================================
/// Aplica un movimiento lineal a un conjunto de particulas.
/// Applies a linear movement to a set of particles.
//==============================================================================
void MoveLinBound(byte periactive,unsigned np,unsigned ini,tdouble3 mvpos,tfloat3 mvvel
  ,const unsigned *ridp,double2 *posxy,double *posz,unsigned *dcell,float4 *velrhop,word *code)
{
  dim3 sgrid=GetGridSize(np,SPHBSIZE);
  if(periactive)KerMoveLinBound<true>  <<<sgrid,SPHBSIZE>>> (np,ini,Double3(mvpos),Float3(mvvel),ridp,posxy,posz,dcell,velrhop,code);
  else          KerMoveLinBound<false> <<<sgrid,SPHBSIZE>>> (np,ini,Double3(mvpos),Float3(mvvel),ridp,posxy,posz,dcell,velrhop,code);
}



//------------------------------------------------------------------------------
/// Aplica un movimiento matricial a un conjunto de particulas.
/// Applies a linear movement to a set of particles.
//------------------------------------------------------------------------------
template<bool periactive,bool simulate2d> __global__ void KerMoveMatBound(unsigned n,unsigned ini,tmatrix4d m,double dt
  ,const unsigned *ridpmv,double2 *posxy,double *posz,unsigned *dcell,float4 *velrhop,word *code)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle
  if(p<n){
    int pid=ridpmv[p+ini];
    if(pid>=0){
      double2 rxy=posxy[pid];
      double3 rpos=make_double3(rxy.x,rxy.y,posz[pid]);
      //-Calcula nueva posicion.
      //-Computes new position.
      double3 rpos2;
      rpos2.x= rpos.x*m.a11 + rpos.y*m.a12 + rpos.z*m.a13 + m.a14;
      rpos2.y= rpos.x*m.a21 + rpos.y*m.a22 + rpos.z*m.a23 + m.a24;
      rpos2.z= rpos.x*m.a31 + rpos.y*m.a32 + rpos.z*m.a33 + m.a34;
      if(simulate2d)rpos2.y=rpos.y;
      //-Calcula desplazamiento y actualiza posicion.
      //-Computes displacement and updates position.
      const double dx=rpos2.x-rpos.x;
      const double dy=rpos2.y-rpos.y;
      const double dz=rpos2.z-rpos.z;
      KerUpdatePos<periactive>(make_double2(rpos.x,rpos.y),rpos.z,dx,dy,dz,false,pid,posxy,posz,dcell,code);
      //-Calcula velocidad.
      //-Computes velocity.
      velrhop[pid]=make_float4(float(dx/dt),float(dy/dt),float(dz/dt),velrhop[pid].w);
    }
  }
}

//==============================================================================
/// Aplica un movimiento matricial a un conjunto de particulas.
/// Applies a linear movement to a set of particles.
//==============================================================================
void MoveMatBound(byte periactive,bool simulate2d,unsigned np,unsigned ini,tmatrix4d m,double dt
  ,const unsigned *ridpmv,double2 *posxy,double *posz,unsigned *dcell,float4 *velrhop,word *code)
{
  dim3 sgrid=GetGridSize(np,SPHBSIZE);
  if(periactive){ const bool peri=true;
    if(simulate2d)KerMoveMatBound<peri,true>  <<<sgrid,SPHBSIZE>>> (np,ini,m,dt,ridpmv,posxy,posz,dcell,velrhop,code);
    else          KerMoveMatBound<peri,false> <<<sgrid,SPHBSIZE>>> (np,ini,m,dt,ridpmv,posxy,posz,dcell,velrhop,code);
  }
  else{ const bool peri=false;
    if(simulate2d)KerMoveMatBound<peri,true>  <<<sgrid,SPHBSIZE>>> (np,ini,m,dt,ridpmv,posxy,posz,dcell,velrhop,code);
    else          KerMoveMatBound<peri,false> <<<sgrid,SPHBSIZE>>> (np,ini,m,dt,ridpmv,posxy,posz,dcell,velrhop,code);
  }
}

//##############################################################################
//# Kernels for Floating bodies.
//##############################################################################
//==============================================================================
/// Calcula distancia entre pariculas floating y centro segun condiciones periodicas.
/// Computes distance between floating and centre particles according to periodic conditions.
//==============================================================================
template<bool periactive> __device__ void KerFtPeriodicDist(double px,double py,double pz,double cenx,double ceny,double cenz,float radius,float &dx,float &dy,float &dz){
  if(periactive){
    double ddx=px-cenx;
    double ddy=py-ceny;
    double ddz=pz-cenz;
    const unsigned peri=CTE.periactive;
    if((peri&1) && fabs(ddx)>radius){
      if(ddx>0){ ddx+=CTE.xperincx; ddy+=CTE.xperincy; ddz+=CTE.xperincz; }
      else{      ddx-=CTE.xperincx; ddy-=CTE.xperincy; ddz-=CTE.xperincz; }
    }
    if((peri&2) && fabs(ddy)>radius){
      if(ddy>0){ ddx+=CTE.yperincx; ddy+=CTE.yperincy; ddz+=CTE.yperincz; }
      else{      ddx-=CTE.yperincx; ddy-=CTE.yperincy; ddz-=CTE.yperincz; }
    }
    if((peri&4) && fabs(ddz)>radius){
      if(ddz>0){ ddx+=CTE.zperincx; ddy+=CTE.zperincy; ddz+=CTE.zperincz; }
      else{      ddx-=CTE.zperincx; ddy-=CTE.zperincy; ddz-=CTE.zperincz; }
    }
    dx=float(ddx);
    dy=float(ddy);
    dz=float(ddz);
  }
  else{
    dx=float(px-cenx);
    dy=float(py-ceny);
    dz=float(pz-cenz);
  }
}

//------------------------------------------------------------------------------
/// Calcula fuerzas sobre floatings.
/// Computes forces on floatings.
//------------------------------------------------------------------------------
template<bool periactive> __global__ void KerFtCalcForces( //fdata={pini,np,radius,mass}
  float3 gravity,const float4 *ftodata,const float *ftomassp,const double3 *ftocenter,const unsigned *ftridp
  ,const double2 *posxy,const double *posz,const float3 *ace
  ,float3 *ftoforces)
{
  extern __shared__ float rfacex[];
  float *rfacey=rfacex+blockDim.x;
  float *rfacez=rfacey+blockDim.x;
  float *rfomegavelx=rfacez+blockDim.x;
  float *rfomegavely=rfomegavelx+blockDim.x;
  float *rfomegavelz=rfomegavely+blockDim.x;
  float *rinert11=rfomegavelz+blockDim.x;
  float *rinert12=rinert11+blockDim.x;
  float *rinert13=rinert12+blockDim.x;
  float *rinert21=rinert13+blockDim.x;
  float *rinert22=rinert21+blockDim.x;
  float *rinert23=rinert22+blockDim.x;
  float *rinert31=rinert23+blockDim.x;
  float *rinert32=rinert31+blockDim.x;
  float *rinert33=rinert32+blockDim.x;

  const unsigned tid=threadIdx.x;                      //-Numero de thread. //-Thread number.
  const unsigned cf=blockIdx.y*gridDim.x + blockIdx.x; //-Numero de floating. //-Floating number
  
  //-Carga datos de floatings.
  //-Loads floating data.
  float4 rfdata=ftodata[cf];
  const unsigned fpini=(unsigned)__float_as_int(rfdata.x);
  const unsigned fnp=(unsigned)__float_as_int(rfdata.y);
  const float fradius=rfdata.z;
  const float fmassp=ftomassp[cf];
  const double3 rcenter=ftocenter[cf];

  //-Inicializa memoria shared a Zero.
  //-Initialises shared memory to zero.
  const unsigned ntid=(fnp<blockDim.x? fnp: blockDim.x); //-Numero de threads utilizados. //-Number of used threads.
  if(tid<ntid){
    rfacex[tid]=rfacey[tid]=rfacez[tid]=0;
    rfomegavelx[tid]=rfomegavely[tid]=rfomegavelz[tid]=0;
    rinert11[tid]=rinert12[tid]=rinert13[tid]=0;
    rinert21[tid]=rinert22[tid]=rinert23[tid]=0;
    rinert31[tid]=rinert32[tid]=rinert33[tid]=0;
  }

  //-Calcula datos en memoria shared.
  //-Computes data in shared memory.
  const unsigned nfor=unsigned((fnp+blockDim.x-1)/blockDim.x);
  for(unsigned cfor=0;cfor<nfor;cfor++){
    unsigned p=cfor*blockDim.x+tid;
    if(p<fnp){
      const unsigned rp=ftridp[p+fpini];
      if(rp!=UINT_MAX){
        float3 race=ace[rp];
        race.x-=gravity.x; race.y-=gravity.y; race.z-=gravity.z;
        rfacex[tid]+=race.x; rfacey[tid]+=race.y; rfacez[tid]+=race.z;
        //-Calcula distancia al centro.
        //-Computes distance from the centre.
        double2 rposxy=posxy[rp];
        float dx,dy,dz;
        KerFtPeriodicDist<periactive>(rposxy.x,rposxy.y,posz[rp],rcenter.x,rcenter.y,rcenter.z,fradius,dx,dy,dz);
        //-Calcula omegavel.
        //-Computes omegavel.
        rfomegavelx[tid]+=(race.z*dy - race.y*dz);
        rfomegavely[tid]+=(race.x*dz - race.z*dx);
        rfomegavelz[tid]+=(race.y*dx - race.x*dy);
        //-Calcula inertia tensor.
        //-Computes inertia tensor.
        rinert11[tid]+= (dy*dy+dz*dz)*fmassp;
        rinert12[tid]+=-(dx*dy)*fmassp;
        rinert13[tid]+=-(dx*dz)*fmassp;
        rinert21[tid]+=-(dx*dy)*fmassp;
        rinert22[tid]+= (dx*dx+dz*dz)*fmassp;
        rinert23[tid]+=-(dy*dz)*fmassp;
        rinert31[tid]+=-(dx*dz)*fmassp;
        rinert32[tid]+=-(dy*dz)*fmassp;
        rinert33[tid]+= (dx*dx+dy*dy)*fmassp;
      }
    }
  }

  //-Reduce datos de memoria shared y guarda resultados.
  //-reduces data in shared memory and stores results.
  __syncthreads();
  if(!tid){
    float3 face=make_float3(0,0,0);
    float3 fomegavel=make_float3(0,0,0);
    float3 inert1=make_float3(0,0,0);
    float3 inert2=make_float3(0,0,0);
    float3 inert3=make_float3(0,0,0);
    for(unsigned c=0;c<ntid;c++){
      face.x+=rfacex[c];  face.y+=rfacey[c];  face.z+=rfacez[c];
      fomegavel.x+=rfomegavelx[c]; fomegavel.y+=rfomegavely[c]; fomegavel.z+=rfomegavelz[c];
      inert1.x+=rinert11[c];  inert1.y+=rinert12[c];  inert1.z+=rinert13[c];
      inert2.x+=rinert21[c];  inert2.y+=rinert22[c];  inert2.z+=rinert23[c];
      inert3.x+=rinert31[c];  inert3.y+=rinert32[c];  inert3.z+=rinert33[c];
    }
    //-Calculates the inverse of the intertia matrix to compute the I^-1 * L= W
    float3 invinert1=make_float3(0,0,0);
    float3 invinert2=make_float3(0,0,0);
    float3 invinert3=make_float3(0,0,0);
    const float detiner=(inert1.x*inert2.y*inert3.z+inert1.y*inert2.z*inert3.x+inert2.x*inert3.y*inert1.z-(inert3.x*inert2.y*inert1.z+inert2.x*inert1.y*inert3.z+inert2.z*inert3.y*inert1.x));
    if(detiner){
      invinert1.x= (inert2.y*inert3.z-inert2.z*inert3.y)/detiner;
      invinert1.y=-(inert1.y*inert3.z-inert1.z*inert3.y)/detiner;
      invinert1.z= (inert1.y*inert2.z-inert1.z*inert2.y)/detiner;
      invinert2.x=-(inert2.x*inert3.z-inert2.z*inert3.x)/detiner;
      invinert2.y= (inert1.x*inert3.z-inert1.z*inert3.x)/detiner;
      invinert2.z=-(inert1.x*inert2.z-inert1.z*inert2.x)/detiner;
      invinert3.x= (inert2.x*inert3.y-inert2.y*inert3.x)/detiner;
      invinert3.y=-(inert1.x*inert3.y-inert1.y*inert3.x)/detiner;
      invinert3.z= (inert1.x*inert2.y-inert1.y*inert2.x)/detiner;
    }
    //-Calcula omega a partir de fomegavel y invinert.
    //-Computes omega from fomegavel and invinert.
    {
      float3 omega;
      omega.x=(fomegavel.x*invinert1.x+fomegavel.y*invinert1.y+fomegavel.z*invinert1.z);
      omega.y=(fomegavel.x*invinert2.x+fomegavel.y*invinert2.y+fomegavel.z*invinert2.z);
      omega.z=(fomegavel.x*invinert3.x+fomegavel.y*invinert3.y+fomegavel.z*invinert3.z);
      fomegavel=omega;
    }
    //-Guarda resultados en ftoforces[].
    //-Stores results in ftoforces[].
    ftoforces[cf*2]=face;
    ftoforces[cf*2+1]=fomegavel;
  }
}

//==============================================================================
/// Calcula fuerzas sobre floatings.
/// Computes forces on floatings.
//==============================================================================
void FtCalcForces(bool periactive,unsigned ftcount
  ,tfloat3 gravity,const float4 *ftodata,const float *ftomassp,const double3 *ftocenter,const unsigned *ftridp
  ,const double2 *posxy,const double *posz,const float3 *ace
  ,float3 *ftoforces)
{
  if(ftcount){
    const unsigned bsize=128;
    const unsigned smem=sizeof(float)*(3+3+9)*bsize;
    dim3 sgrid=GetGridSize(ftcount*bsize,bsize);
    if(periactive)KerFtCalcForces<true>  <<<sgrid,bsize,smem>>> (Float3(gravity),ftodata,ftomassp,ftocenter,ftridp,posxy,posz,ace,ftoforces);
    else          KerFtCalcForces<false> <<<sgrid,bsize,smem>>> (Float3(gravity),ftodata,ftomassp,ftocenter,ftridp,posxy,posz,ace,ftoforces);
  }
}

//------------------------------------------------------------------------------
/// Updates information and particles of floating bodies.
//------------------------------------------------------------------------------
template<bool periactive> __global__ void KerFtUpdate(bool predictor,bool simulate2d//fdata={pini,np,radius,mass}
  ,double dt,float3 gravity,const float4 *ftodata,const unsigned *ftridp
  ,const float3 *ftoforces,double3 *ftocenter,float3 *ftovel,float3 *ftoomega
  ,double2 *posxy,double *posz,unsigned *dcell,float4 *velrhop,word *code)
{
  const unsigned tid=threadIdx.x;                      //-Numero de thread. //-Thread number.
  const unsigned cf=blockIdx.y*gridDim.x + blockIdx.x; //-Numero de floating. //floating number.
  //-Obtiene datos de floating.
  //-Obtains floating data.
  float4 rfdata=ftodata[cf];
  const unsigned fpini=(unsigned)__float_as_int(rfdata.x);
  const unsigned fnp=(unsigned)__float_as_int(rfdata.y);
  const float fradius=rfdata.z;
  const float fmass=rfdata.w;
  //-Calculo de face.
  //-Face computation.
  float3 face=ftoforces[cf*2];
  face.x=(face.x+fmass*gravity.x)/fmass;
  face.y=(face.y+fmass*gravity.y)/fmass;
  face.z=(face.z+fmass*gravity.z)/fmass;
  //-Calculo de fomega.
  //-fomega computation.
  float3 fomega=ftoomega[cf];
  {
    const float3 omega=ftoforces[cf*2+1];
    fomega.x=float(dt*omega.x+fomega.x);
    fomega.y=float(dt*omega.y+fomega.y);
    fomega.z=float(dt*omega.z+fomega.z);
  }
  float3 fvel=ftovel[cf];
  //-Anula componentes para 2D.
  //-Remove y components for 2D.
  if(simulate2d){ face.y=0; fomega.x=0; fomega.z=0; fvel.y=0; }
  //-Calculo de fcenter.
  //-fcenter computation.
  double3 fcenter=ftocenter[cf];
  fcenter.x+=dt*fvel.x;
  fcenter.y+=dt*fvel.y;
  fcenter.z+=dt*fvel.z;
  //-Calculo de fvel.
  //-fvel computation.
  fvel.x=float(dt*face.x+fvel.x);
  fvel.y=float(dt*face.y+fvel.y);
  fvel.z=float(dt*face.z+fvel.z);

  //-Updates floating particles.
  const unsigned nfor=unsigned((fnp+blockDim.x-1)/blockDim.x);
  for(unsigned cfor=0;cfor<nfor;cfor++){
    unsigned fp=cfor*blockDim.x+tid;
    if(fp<fnp){
      const unsigned p=ftridp[fp+fpini];
      if(p!=UINT_MAX){
        double2 rposxy=posxy[p];
        double rposz=posz[p];
        float4 rvel=velrhop[p];
        //-Calcula y graba desplazamiento de posicion.
        //-Computes and stores position displacement.
        const double dx=dt*double(rvel.x);
        const double dy=dt*double(rvel.y);
        const double dz=dt*double(rvel.z);
        KerUpdatePos<periactive>(rposxy,rposz,dx,dy,dz,false,p,posxy,posz,dcell,code);
        //-Calcula y graba nueva velocidad.
        //-Computes and stores new velocity.
        float disx,disy,disz;
        KerFtPeriodicDist<periactive>(rposxy.x+dx,rposxy.y+dy,rposz+dz,fcenter.x,fcenter.y,fcenter.z,fradius,disx,disy,disz);
        rvel.x=fvel.x+(fomega.y*disz-fomega.z*disy);
        rvel.y=fvel.y+(fomega.z*disx-fomega.x*disz);
        rvel.z=fvel.z+(fomega.x*disy-fomega.y*disx);
        velrhop[p]=rvel;
      }
    }
  }

  //-Stores floating data.
  __syncthreads();
  if(!tid && !predictor){
    ftocenter[cf]=(periactive? KerUpdatePeriodicPos(fcenter): fcenter);
    ftovel[cf]=fvel;
    ftoomega[cf]=fomega;
  }
}

//==============================================================================
/// Updates information and particles of floating bodies.
//==============================================================================
void FtUpdate(bool periactive,bool predictor,bool simulate2d,unsigned ftcount
  ,double dt,tfloat3 gravity,const float4 *ftodata,const unsigned *ftridp
  ,const float3 *ftoforces,double3 *ftocenter,float3 *ftovel,float3 *ftoomega
  ,double2 *posxy,double *posz,unsigned *dcell,float4 *velrhop,word *code)
{
  if(ftcount){
    const unsigned bsize=128;
    dim3 sgrid=GetGridSize(ftcount*bsize,bsize);
    if(periactive)KerFtUpdate<true>  <<<sgrid,bsize>>> (predictor,simulate2d,dt,Float3(gravity),ftodata,ftridp,ftoforces,ftocenter,ftovel,ftoomega,posxy,posz,dcell,velrhop,code);
    else          KerFtUpdate<false> <<<sgrid,bsize>>> (predictor,simulate2d,dt,Float3(gravity),ftodata,ftridp,ftoforces,ftocenter,ftovel,ftoomega,posxy,posz,dcell,velrhop,code);
  }
}


//##############################################################################
//# Kernels para Periodic conditions
//# Kernels for Periodic conditions
//##############################################################################
//------------------------------------------------------------------------------
/// Marca las periodicas actuales como ignorar.
/// Marks current periodics to be ignored.
//------------------------------------------------------------------------------
__global__ void KerPeriodicIgnore(unsigned n,word *code)
{
  const unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle
  if(p<n){
    //-Comprueba codigo de particula.
    //-Checks code of particles.
    const word rcode=code[p];
    if(CODE_GetSpecialValue(rcode)==CODE_PERIODIC)code[p]=CODE_SetOutIgnore(rcode);
  }
}

//==============================================================================
/// Marca las periodicas actuales como ignorar.
/// Marks current periodics to be ignored.
//==============================================================================
void PeriodicIgnore(unsigned n,word *code){
  if(n){
    dim3 sgrid=GetGridSize(n,SPHBSIZE);
    KerPeriodicIgnore <<<sgrid,SPHBSIZE>>> (n,code);
  }
}

//------------------------------------------------------------------------------
/// Crea lista de nuevas particulas periodicas a duplicar y con delper activado
/// marca las periodicas viejas para ignorar.
/// Create list of new periodic particles to be duplicated and 
/// marks old periodics to be ignored.
//------------------------------------------------------------------------------
__global__ void KerPeriodicMakeList(unsigned n,unsigned pini,unsigned nmax
  ,double3 mapposmin,double3 mapposmax,double3 perinc
  ,const double2 *posxy,const double *posz,const word *code,unsigned *listp)
{
  extern __shared__ unsigned slist[];
  if(!threadIdx.x)slist[0]=0;
  __syncthreads();
  const unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle
  if(p<n){
    const unsigned p2=p+pini;
    //-Se queda con particulas normales o periodicas.
    //-Inteacts with normal or periodic particles.
    if(CODE_GetSpecialValue(code[p2])<=CODE_PERIODIC){
      //-Obtiene posicion de particula.
      //-Obtains particle position.
      const double2 rxy=posxy[p2];
      const double rx=rxy.x,ry=rxy.y;
      const double rz=posz[p2];
      double rx2=rx+perinc.x,ry2=ry+perinc.y,rz2=rz+perinc.z;
      if(mapposmin.x<=rx2 && mapposmin.y<=ry2 && mapposmin.z<=rz2 && rx2<mapposmax.x && ry2<mapposmax.y && rz2<mapposmax.z){
        unsigned cp=atomicAdd(slist,1);  slist[cp+1]=p2;
      }
      rx2=rx-perinc.x; ry2=ry-perinc.y; rz2=rz-perinc.z;
      if(mapposmin.x<=rx2 && mapposmin.y<=ry2 && mapposmin.z<=rz2 && rx2<mapposmax.x && ry2<mapposmax.y && rz2<mapposmax.z){
        unsigned cp=atomicAdd(slist,1);  slist[cp+1]=(p2|0x80000000);
      }
    }
  }
  __syncthreads();
  const unsigned ns=slist[0];
  __syncthreads();
  if(!threadIdx.x && ns)slist[0]=atomicAdd((listp+nmax),ns);
  __syncthreads();
  if(threadIdx.x<ns){
    unsigned cp=slist[0]+threadIdx.x;
    if(cp<nmax)listp[cp]=slist[threadIdx.x+1];
  }
  if(blockDim.x+threadIdx.x<ns){//-Puede haber el doble de periodicas que threads. //-There may be twice as many periodics per thread
    unsigned cp=blockDim.x+slist[0]+threadIdx.x;
    if(cp<nmax)listp[cp]=slist[blockDim.x+threadIdx.x+1];
  }
}

//==============================================================================
/// Crea lista de nuevas particulas periodicas a duplicar.
/// Con stable activado reordena lista de periodicas.
/// Create list of new periodic particles to be duplicated.
/// With stable activated reorders perioc list.
//==============================================================================
unsigned PeriodicMakeList(unsigned n,unsigned pini,bool stable,unsigned nmax
  ,tdouble3 mapposmin,tdouble3 mapposmax,tdouble3 perinc
  ,const double2 *posxy,const double *posz,const word *code,unsigned *listp)
{
  unsigned count=0;
  if(n){
    //-Inicializa tama�o de lista lspg a cero.
    //-Lspg size list initialized to zero.
    cudaMemset(listp+nmax,0,sizeof(unsigned));
    dim3 sgrid=GetGridSize(n,SPHBSIZE);
    const unsigned smem=(SPHBSIZE*2+1)*sizeof(unsigned); //-De cada particula pueden salir 2 nuevas periodicas mas la posicion del contador. //-Each particle can leave two new periodic over the counter position.
    KerPeriodicMakeList <<<sgrid,SPHBSIZE,smem>>> (n,pini,nmax,Double3(mapposmin),Double3(mapposmax),Double3(perinc),posxy,posz,code,listp);
    cudaMemcpy(&count,listp+nmax,sizeof(unsigned),cudaMemcpyDeviceToHost);
    //-Reordena lista si es valida y stable esta activado.
    //-Reorders list if it is valid and stable has been activated.
    if(stable && count && count<=nmax){
      thrust::device_ptr<unsigned> dev_list(listp);
      thrust::sort(dev_list,dev_list+count);
    }
  }
  return(count);
}

//------------------------------------------------------------------------------
/// Duplica la posicion de la particula indicada aplicandole un desplazamiento.
/// Las particulas duplicadas se considera que siempre son validas y estan dentro
/// del dominio.
/// Este kernel vale para single-gpu y multi-gpu porque los calculos se hacen 
/// a partir de domposmin.
/// Se controla que las coordendas de celda no sobrepasen el maximo.
/// Doubles the position of the indicated particle using a displacement.
/// Duplicate particles are considered valid and are always within
/// the domain.
/// This kernel applies to single-GPU and multi-GPU because the calculations are made
/// from domposmin.
/// It controls the cell coordinates not exceed the maximum.
//------------------------------------------------------------------------------
__device__ void KerPeriodicDuplicatePos(unsigned pnew,unsigned pcopy
  ,bool inverse,double dx,double dy,double dz,uint3 cellmax
  ,double2 *posxy,double *posz,unsigned *dcell)
{
  //-Obtiene pos de particula a duplicar.
  //-Obtainsposition of the particle to be duplicated.
  double2 rxy=posxy[pcopy];
  double rz=posz[pcopy];
  //-Aplica desplazamiento.
  //-Applies displacement.
  rxy.x+=(inverse? -dx: dx);
  rxy.y+=(inverse? -dy: dy);
  rz+=(inverse? -dz: dz);
  //-Calcula coordendas de celda dentro de dominio.
  //-Computes cell coordinates within the domain.
  unsigned cx=unsigned((rxy.x-CTE.domposminx)/CTE.scell);
  unsigned cy=unsigned((rxy.y-CTE.domposminy)/CTE.scell);
  unsigned cz=unsigned((rz-CTE.domposminz)/CTE.scell);
  //-Ajusta las coordendas de celda si sobrepasan el maximo.
  //-Adjust cell coordinates if they exceed the maximum.
  cx=(cx<=cellmax.x? cx: cellmax.x);
  cy=(cy<=cellmax.y? cy: cellmax.y);
  cz=(cz<=cellmax.z? cz: cellmax.z);
  //-Graba posicion y celda de nuevas particulas.
  //-Stores position and cell of the new particles.
  posxy[pnew]=rxy;
  posz[pnew]=rz;
  dcell[pnew]=PC__Cell(CTE.cellcode,cx,cy,cz);
}

//------------------------------------------------------------------------------
/// Crea particulas periodicas a partir de una lista con las particulas a duplicar.
/// Se presupone que todas las particulas son validas.
/// Este kernel vale para single-gpu y multi-gpu porque usa domposmin. 
/// Creates periodic particles from a list of particles to duplicate.
/// It is assumed that all particles are valid.
/// This kernel applies to single-GPU and multi-GPU because it uses domposmin.
//------------------------------------------------------------------------------
__global__ void KerPeriodicDuplicateVerlet(unsigned n,unsigned pini,uint3 cellmax,double3 perinc
  ,const unsigned *listp,unsigned *idp,word *code,unsigned *dcell
  ,double2 *posxy,double *posz,float4 *velrhop,tsymatrix3f *spstau,float4 *velrhopm1)
{
  const unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle
  if(p<n){
    const unsigned pnew=p+pini;
    const unsigned rp=listp[p];
    const unsigned pcopy=(rp&0x7FFFFFFF);
    //-Ajusta posicion y celda de nueva particula.
    //-Adjusts cell position of the new particles.
    KerPeriodicDuplicatePos(pnew,pcopy,(rp>=0x80000000),perinc.x,perinc.y,perinc.z,cellmax,posxy,posz,dcell);
    //-Copia el resto de datos.
    //-Copies the remaining data.
    idp[pnew]=idp[pcopy];
    code[pnew]=CODE_SetPeriodic(code[pcopy]);
    velrhop[pnew]=velrhop[pcopy];
    velrhopm1[pnew]=velrhopm1[pcopy];
    if(spstau)spstau[pnew]=spstau[pcopy];
  }
}

//==============================================================================
/// Crea particulas periodicas a partir de una lista con las particulas a duplicar.
/// Creates periodic particles from a list of particles to duplicate.
//==============================================================================
void PeriodicDuplicateVerlet(unsigned n,unsigned pini,tuint3 domcells,tdouble3 perinc
  ,const unsigned *listp,unsigned *idp,word *code,unsigned *dcell
  ,double2 *posxy,double *posz,float4 *velrhop,tsymatrix3f *spstau,float4 *velrhopm1)
{
  if(n){
    uint3 cellmax=make_uint3(domcells.x-1,domcells.y-1,domcells.z-1);
    dim3 sgrid=GetGridSize(n,SPHBSIZE);
    KerPeriodicDuplicateVerlet <<<sgrid,SPHBSIZE>>> (n,pini,cellmax,Double3(perinc),listp,idp,code,dcell,posxy,posz,velrhop,spstau,velrhopm1);
  }
}

//------------------------------------------------------------------------------
/// Crea particulas periodicas a partir de una lista con las particulas a duplicar.
/// Se presupone que todas las particulas son validas.
/// Este kernel vale para single-gpu y multi-gpu porque usa domposmin. 
/// Creates periodic particles from a list of particles to duplicate.
/// It is assumed that all particles are valid.
/// This kernel applies to single-GPU and multi-GPU because it uses domposmin.
//------------------------------------------------------------------------------
template<bool varspre> __global__ void KerPeriodicDuplicateSymplectic(unsigned n,unsigned pini
  ,uint3 cellmax,double3 perinc,const unsigned *listp,unsigned *idp,word *code,unsigned *dcell
  ,double2 *posxy,double *posz,float4 *velrhop,tsymatrix3f *spstau,double2 *posxypre,double *poszpre,float4 *velrhoppre)
{
  const unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-N� de la part�cula //-NI of the particle
  if(p<n){
    const unsigned pnew=p+pini;
    const unsigned rp=listp[p];
    const unsigned pcopy=(rp&0x7FFFFFFF);
    //-Ajusta posicion y celda de nueva particula.
    //-Adjusts cell position of the new particles.
    KerPeriodicDuplicatePos(pnew,pcopy,(rp>=0x80000000),perinc.x,perinc.y,perinc.z,cellmax,posxy,posz,dcell);
    //-Copia el resto de datos.
    //-Copies the remaining data.
    idp[pnew]=idp[pcopy];
    code[pnew]=CODE_SetPeriodic(code[pcopy]);
    velrhop[pnew]=velrhop[pcopy];
    if(varspre){
      posxypre[pnew]=posxypre[pcopy];
      poszpre[pnew]=poszpre[pcopy];
      velrhoppre[pnew]=velrhoppre[pcopy];
    }
    if(spstau)spstau[pnew]=spstau[pcopy];
  }
}

//==============================================================================
/// Crea particulas periodicas a partir de una lista con las particulas a duplicar.
/// Creates periodic particles from a list of particles to duplicate.
//==============================================================================
void PeriodicDuplicateSymplectic(unsigned n,unsigned pini
  ,tuint3 domcells,tdouble3 perinc,const unsigned *listp,unsigned *idp,word *code,unsigned *dcell
  ,double2 *posxy,double *posz,float4 *velrhop,tsymatrix3f *spstau,double2 *posxypre,double *poszpre,float4 *velrhoppre)
{
  if(n){
    uint3 cellmax=make_uint3(domcells.x-1,domcells.y-1,domcells.z-1);
    dim3 sgrid=GetGridSize(n,SPHBSIZE);
    if(posxypre!=NULL)KerPeriodicDuplicateSymplectic<true>  <<<sgrid,SPHBSIZE>>> (n,pini,cellmax,Double3(perinc),listp,idp,code,dcell,posxy,posz,velrhop,spstau,posxypre,poszpre,velrhoppre);
    else              KerPeriodicDuplicateSymplectic<false> <<<sgrid,SPHBSIZE>>> (n,pini,cellmax,Double3(perinc),listp,idp,code,dcell,posxy,posz,velrhop,spstau,posxypre,poszpre,velrhoppre);
  }
}


//##############################################################################
//# Kernels para external forces (JSphAccInput)
//# Kernels for external forces (JSphAccInput)
//##############################################################################
//------------------------------------------------------
/// Adds variable forces to particle sets.
//------------------------------------------------------
__global__ void KerAddAccInputAng(unsigned n,unsigned pini,word codesel,float3 gravity
  ,bool setgravity,double3 acclin,double3 accang,double3 centre,double3 velang,double3 vellin
  ,const word *code,const double2 *posxy,const double *posz,const float4 *velrhop,float3 *ace)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x;
  if(p<n){
    p+=pini;
    //Check if the current particle is part of the particle set by its Mk
    if(CODE_GetTypeValue(code[p])==codesel){
      const float3 accf=ace[p]; //-Gets the current particles acceleration value.
      double accx=accf.x,accy=accf.y,accz=accf.z;
      //-Adds linear acceleration.
      accx+=acclin.x;  accy+=acclin.y;  accz+=acclin.z;
      //-Subtract global gravity from the acceleration if it is set in the input file
      if(!setgravity){
        accx-=gravity.x;  accy-=gravity.y;  accz-=gravity.z; 
      }

      //-Adds angular acceleration.
      const double2 rxy=posxy[p];
      const double dcx=rxy.x-centre.x;
      const double dcy=rxy.y-centre.y;
      const double dcz=posz[p]-centre.z;
      //-Get the current particle's velocity
      const float4 rvel=velrhop[p];
      const double velx=rvel.x;
      const double vely=rvel.y;
      const double velz=rvel.z;

      //-Calculate angular acceleration ((Dw/Dt) x (r_i - r)) + (w x (w x (r_i - r))) + (2w x (v_i - v))
      //(Dw/Dt) x (r_i - r) (term1)
      accx+=(accang.y*dcz)-(accang.z*dcy);
      accy+=(accang.z*dcx)-(accang.x*dcz);
      accz+=(accang.x*dcy)-(accang.y*dcx);

      //Centripetal acceleration (term2)
      //First find w x (r_i - r))
      const double innerx=(velang.y*dcz)-(velang.z*dcy);
      const double innery=(velang.z*dcx)-(velang.x*dcz);
      const double innerz=(velang.x*dcy)-(velang.y*dcx);
      //Find w x inner
      accx+=(velang.y*innerz)-(velang.z*innery);
      accy+=(velang.z*innerx)-(velang.x*innerz);
      accz+=(velang.x*innery)-(velang.y*innerx);

      //Coriolis acceleration 2w x (v_i - v) (term3)
      accx+=((2.0*velang.y)*velz)-((2.0*velang.z)*(vely-vellin.y));
      accy+=((2.0*velang.z)*velx)-((2.0*velang.x)*(velz-vellin.z));
      accz+=((2.0*velang.x)*vely)-((2.0*velang.y)*(velx-vellin.x));

      //-Stores the new acceleration value.
      ace[p]=make_float3(float(accx),float(accy),float(accz));
    }
  }
}

//------------------------------------------------------
/// Adds variable forces to particle sets.
//------------------------------------------------------
__global__ void KerAddAccInputLin(unsigned n,unsigned pini,word codesel,float3 gravity
  ,bool setgravity,double3 acclin,const word *code,float3 *ace)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x;
  if(p<n){
    p+=pini;
    //Check if the current particle is part of the particle set by its Mk
    if(CODE_GetTypeValue(code[p])==codesel){
      const float3 accf=ace[p]; //-Gets the current particles acceleration value.
      double accx=accf.x,accy=accf.y,accz=accf.z;
      //-Adds linear acceleration.
      accx+=acclin.x;  accy+=acclin.y;  accz+=acclin.z;
      //-Subtract global gravity from the acceleration if it is set in the input file
      if(!setgravity){
        accx-=gravity.x;  accy-=gravity.y;  accz-=gravity.z; 
      }
      //-Stores the new acceleration value.
      ace[p]=make_float3(float(accx),float(accy),float(accz));
    }
  }
}

//==================================================================================================
/// Adds variable acceleration forces for particle MK groups that have an input file.
//==================================================================================================
void AddAccInput(unsigned n,unsigned pini,word codesel
  ,tdouble3 acclin,tdouble3 accang,tdouble3 centre,tdouble3 velang,tdouble3 vellin,bool setgravity
  ,tfloat3 gravity,const word *code,const double2 *posxy,const double *posz,const float4 *velrhop,float3 *ace)
{
  if(n){
    dim3 sgrid=GetGridSize(n,SPHBSIZE);
    const bool withaccang=(accang.x!=0 || accang.y!=0 || accang.z!=0);
    if(withaccang)KerAddAccInputAng <<<sgrid,SPHBSIZE>>> (n,pini,codesel,Float3(gravity),setgravity,Double3(acclin),Double3(accang),Double3(centre),Double3(velang),Double3(vellin),code,posxy,posz,velrhop,ace);
    else          KerAddAccInputLin <<<sgrid,SPHBSIZE>>> (n,pini,codesel,Float3(gravity),setgravity,Double3(acclin),code,ace);
  }
}



}



