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

/// \file JSphGpu.cpp \brief Implements the class \ref JSphGpu.

#include "JSphGpu.h"
#include "JSphGpu_ker.h"
#include "JBlockSizeAuto.h"
#include "JCellDivGpu.h"
#include "JPartFloatBi4.h"
#include "Functions.h"
#include "JSphMotion.h"
#include "JArraysGpu.h"
#include "JSphDtFixed.h"
#include "JSaveDt.h"
#include "JTimeOut.h"
#include "JWaveGen.h"
#include "JSphAccInput.h"
#include "JXml.h"

#ifndef WIN32
  #include <unistd.h>
#endif

using namespace std;

//==============================================================================
/// Constructor.
//==============================================================================
JSphGpu::JSphGpu():JSph(false){
  ClassName="JSphGpu";
  Idp=NULL; Code=NULL; Dcell=NULL; Posxy=NULL; Posz=NULL; Velrhop=NULL;
  AuxPos=NULL; AuxVel=NULL; AuxRhop=NULL;
  FtoForces=NULL; FtoCenter=NULL;   //-Floatings.
  CellDiv=NULL;
//�����������������������������������������������������������������������//MP
  PhaseData=NULL;
//�����������������������������������������������������������������������//MP
  ArraysGpu=new JArraysGpu;
  InitVars();
  TmgCreation(Timers,false);
  BsAuto=NULL;
}

//==============================================================================
/// Destructor.
//==============================================================================
JSphGpu::~JSphGpu(){
  FreeCpuMemoryParticles();
  FreeGpuMemoryParticles();
  FreeGpuMemoryFixed();
  delete ArraysGpu;
  TmgDestruction(Timers);
  cudaDeviceReset();
  delete BsAuto; BsAuto=NULL;
//�����������������������������������������������������������������������//MP
  delete PhaseData;
//�����������������������������������������������������������������������//MP
}

//==============================================================================
/// Initialisation of variables.
//==============================================================================
void JSphGpu::InitVars(){
  RunMode="";
  memset(&BlockSizes,0,sizeof(StBlockSizes));
  BlockSizesStr="";
  BlockSizeMode=BSIZEMODE_Fixed;

  Np=Npb=NpbOk=0;
  NpbPer=NpfPer=0;
  WithFloating=false;

  FreeCpuMemoryParticles();
  Idpg=NULL; Codeg=NULL; Dcellg=NULL; Posxyg=NULL; Poszg=NULL; Velrhopg=NULL;
  VelrhopM1g=NULL;                                 //-Verlet
  PosxyPreg=NULL; PoszPreg=NULL; VelrhopPreg=NULL; //-Symplectic
  PsPospressg=NULL;                                //-Interaccion Pos-Simple. //-Interaction Pos-Simple
  SpsTaug=NULL; SpsGradvelg=NULL;                  //-Laminar+SPS. 
  ViscDtg=NULL; 
  Arg=NULL; Aceg=NULL; Deltag=NULL;
  ShiftPosg=NULL; ShiftDetectg=NULL; //-Shifting.
  RidpMoveg=NULL;
  FtRidpg=NULL;    FtoMasspg=NULL;               //-Floatings.
  FtoDatag=NULL;   FtoForcesg=NULL;              //-Calculo de fuerzas en floatings.  //-Calculates forces on floating bodies
  FtoCenterg=NULL; FtoVelg=NULL; FtoOmegag=NULL; //-Gestion de floatings. //-Management of floating bodies
  DemDatag=NULL; //(DEM)
  FreeGpuMemoryParticles();
  FreeGpuMemoryFixed();
//�����������������������������������������������������������������������//MP
  SurfCoef=false;
  Surfg=NULL;
  PhaseDatag=NULL;
//�����������������������������������������������������������������������//MP
}

//==============================================================================
/// Lanza excepcion por un error Cuda.
/// Throws exception for an error in the CUDA code
//==============================================================================
void JSphGpu::RunExceptionCuda(const std::string &method,const std::string &msg,cudaError_t error){
  std::string tx=fun::PrintStr("%s (CUDA error: %s).\n",msg.c_str(),cudaGetErrorString(error)); 
  Log->Print(GetExceptionText(method,tx));
  RunException(method,msg);
}

//==============================================================================
/// Comprueba error y lanza excepcion si lo hubiera.
/// Checks error and throws exception.
//==============================================================================
void JSphGpu::CheckCudaError(const std::string &method,const std::string &msg){
  cudaError_t err=cudaGetLastError();
  if(err!=cudaSuccess)RunExceptionCuda(method,msg,err);
}

//==============================================================================
/// Libera memoria fija en Gpu para moving y floating.
/// Releases fixed memory on the GPU for moving and floating bodies
//==============================================================================
void JSphGpu::FreeGpuMemoryFixed(){
  MemGpuFixed=0;
  if(RidpMoveg)cudaFree(RidpMoveg);   RidpMoveg=NULL;
  if(FtRidpg)cudaFree(FtRidpg);       FtRidpg=NULL;
  if(FtoMasspg)cudaFree(FtoMasspg);   FtoMasspg=NULL;
  if(FtoDatag)cudaFree(FtoDatag);     FtoDatag=NULL;
  if(FtoForcesg)cudaFree(FtoForcesg); FtoForcesg=NULL;
  if(FtoCenterg)cudaFree(FtoCenterg); FtoCenterg=NULL;
  if(FtoVelg)cudaFree(FtoVelg);       FtoVelg=NULL;
  if(FtoOmegag)cudaFree(FtoOmegag);   FtoOmegag=NULL;
  if(DemDatag)cudaFree(DemDatag);     DemDatag=NULL;
}

//==============================================================================
/// Allocates memory for arrays with fixed size (motion and floating bodies).
//==============================================================================
void JSphGpu::AllocGpuMemoryFixed(){
  MemGpuFixed=0;
  //-Allocates memory for moving objects.
  if(CaseNmoving){
    size_t m=sizeof(unsigned)*CaseNmoving;
    cudaMalloc((void**)&RidpMoveg,m);   MemGpuFixed+=m;
  }
  //-Allocates memory for floating bodies.
  if(CaseNfloat){
    size_t m=sizeof(unsigned)*CaseNfloat;
    cudaMalloc((void**)&FtRidpg,m);     MemGpuFixed+=m;
    m=sizeof(float)*FtCount;
    cudaMalloc((void**)&FtoMasspg,m);   MemGpuFixed+=m;
    m=sizeof(float4)*FtCount;
    cudaMalloc((void**)&FtoDatag,m);    MemGpuFixed+=m;
    m=sizeof(float3)*2*FtCount;
    cudaMalloc((void**)&FtoForcesg,m);  MemGpuFixed+=m;
    m=sizeof(double3)*FtCount;
    cudaMalloc((void**)&FtoCenterg,m);  MemGpuFixed+=m;
    m=sizeof(float3)*CaseNfloat;
    cudaMalloc((void**)&FtoVelg,m);     MemGpuFixed+=m;
    m=sizeof(float3)*FtCount;
    cudaMalloc((void**)&FtoOmegag,m);   MemGpuFixed+=m;
  }
  if(UseDEM){ //(DEM)
    size_t m=sizeof(float4)*DemObjsSize;
    cudaMalloc((void**)&DemDatag,m);    MemGpuFixed+=m;
  }
}

//==============================================================================
/// Libera memoria para datos principales de particulas.
/// Releases memory for the main particle data.
//==============================================================================
void JSphGpu::FreeCpuMemoryParticles(){
  CpuParticlesSize=0;
  MemCpuParticles=0;
  delete[] Idp;        Idp=NULL;
  delete[] Code;       Code=NULL;
  delete[] Dcell;      Dcell=NULL;
  delete[] Posxy;      Posxy=NULL;
  delete[] Posz;       Posz=NULL;
  delete[] Velrhop;    Velrhop=NULL;
  delete[] AuxPos;     AuxPos=NULL;
  delete[] AuxVel;     AuxVel=NULL;
  delete[] AuxRhop;    AuxRhop=NULL;
  delete[] FtoForces;  FtoForces=NULL;
  delete[] FtoCenter;  FtoCenter=NULL;
//�����������������������������������������������������������������������//MP
  delete[] PhaseData;  PhaseData=NULL;
//�����������������������������������������������������������������������//MP
}

//==============================================================================
/// Reserva memoria para datos principales de particulas.
/// Allocates memory for the main particle data.
//==============================================================================
void JSphGpu::AllocCpuMemoryParticles(unsigned np){
  const char* met="AllocCpuMemoryParticles";
  FreeCpuMemoryParticles();
  CpuParticlesSize=np;
  if(np>0){
    try{
      Idp=new unsigned[np];      MemCpuParticles+=sizeof(unsigned)*np;
      Code=new word[np];         MemCpuParticles+=sizeof(word)*np;
      Dcell=new unsigned[np];    MemCpuParticles+=sizeof(unsigned)*np;
      Posxy=new tdouble2[np];    MemCpuParticles+=sizeof(tdouble2)*np;
      Posz=new double[np];       MemCpuParticles+=sizeof(double)*np;
      Velrhop=new tfloat4[np];   MemCpuParticles+=sizeof(tfloat4)*np;
      AuxPos=new tdouble3[np];   MemCpuParticles+=sizeof(tdouble3)*np; 
      AuxVel=new tfloat3[np];    MemCpuParticles+=sizeof(tfloat3)*np;
      AuxRhop=new float[np];     MemCpuParticles+=sizeof(float)*np;
      //-Memoria auxiliar para floatings.
      //-Auxiliary memory for floating bodies.
      FtoForces=new StFtoForces[FtCount];  MemCpuParticles+=sizeof(StFtoForces)*FtCount;
      FtoCenter=new tdouble3[FtCount];     MemCpuParticles+=sizeof(tdouble3)*FtCount;
//�����������������������������������������������������������������������//MP
	  PhaseData=new StPhaseData[MkListSize];	MemCpuParticles+=sizeof(StPhaseData)*MkListSize;
//�����������������������������������������������������������������������//MP
    }
    catch(const std::bad_alloc){
      RunException(met,fun::PrintStr("Could not allocate the requested memory (np=%u).",np));
    }
  }
}

//==============================================================================
/// Libera memoria en Gpu para particulas.
/// Release GPU memory for the particles.
//==============================================================================
void JSphGpu::FreeGpuMemoryParticles(){
  GpuParticlesSize=0;
  MemGpuParticles=0;
  ArraysGpu->Reset();
}

//==============================================================================
/// Reserva memoria en Gpu para las particulas. 
/// Allocates GPU memory for the particles.
//==============================================================================
void JSphGpu::AllocGpuMemoryParticles(unsigned np,float over){
  const char* met="AllocGpuMemoryParticles";
  FreeGpuMemoryParticles();
  //-Calcula numero de particulas para las que se reserva memoria.
  //-Computes number of particles for which memory will be allocated
  const unsigned np2=(over>0? unsigned(over*np): np);
  GpuParticlesSize=np2;
  //-Calcula cuantos arrays.
  //-Compute total number of arrays
  ArraysGpu->SetArraySize(np2);
  ArraysGpu->AddArrayCount(JArraysGpu::SIZE_2B,2);  //-code,code2
  ArraysGpu->AddArrayCount(JArraysGpu::SIZE_4B,4);  //-idp,ar,viscdt,dcell
  if(TDeltaSph==DELTA_DynamicExt)ArraysGpu->AddArrayCount(JArraysGpu::SIZE_4B,1);  //-delta
  ArraysGpu->AddArrayCount(JArraysGpu::SIZE_12B,1); //-ace
  ArraysGpu->AddArrayCount(JArraysGpu::SIZE_16B,4); //-velrhop,posxy
  ArraysGpu->AddArrayCount(JArraysGpu::SIZE_8B,2);  //-posz
  if(TStep==STEP_Verlet){
    ArraysGpu->AddArrayCount(JArraysGpu::SIZE_16B,1); //-velrhopm1
  }
  else if(TStep==STEP_Symplectic){
    ArraysGpu->AddArrayCount(JArraysGpu::SIZE_8B,1);  //-poszpre
    ArraysGpu->AddArrayCount(JArraysGpu::SIZE_16B,2); //-posxypre,velrhoppre
  }
  if(TVisco==VISCO_LaminarSPS){     
    ArraysGpu->AddArrayCount(JArraysGpu::SIZE_24B,2); //-SpsTau,SpsGradvel
  }
  if(CaseNfloat){
    ArraysGpu->AddArrayCount(JArraysGpu::SIZE_4B,4);  //-FtMasspg
  }
  if(TShifting!=SHIFT_None){
    ArraysGpu->AddArrayCount(JArraysGpu::SIZE_12B,1); //-shiftpos
    /*if(ShiftTFS)*/ArraysGpu->AddArrayCount(JArraysGpu::SIZE_4B,1); //-shiftdetectc
  }
//�����������������������������������������������������������������������//MP
  if(TPhase==FLOW_Multi){
    size_t multi=sizeof(StPhaseData)*MkListSize;
    cudaMalloc((void**)&PhaseDatag,multi);
  }
  if(SurfCoef){
	  ArraysGpu->AddArrayCount(JArraysGpu::SIZE_24B,1);   //-surfg
  }
//�����������������������������������������������������������������������//MP
  //-Muestra la memoria reservada.
  //-Shows the allocated memory
  MemGpuParticles=ArraysGpu->GetAllocMemoryGpu();
//�����������������������������������������������������������������������//MP
  if(TPhase==FLOW_Multi) {
    size_t multi=sizeof(StPhaseData)*MkListSize;
	MemGpuParticles+=multi;
  }
//�����������������������������������������������������������������������//MP
  PrintSizeNp(np2,MemGpuParticles);
  CheckCudaError(met,"Failed GPU memory allocation.");
}

//==============================================================================
/// Resizes space in GPU memory for particles.
//==============================================================================
void JSphGpu::ResizeGpuMemoryParticles(unsigned npnew){
  //-Saves current data from GPU.
  unsigned    *idp       =SaveArrayGpu(Np,Idpg);
  word        *code      =SaveArrayGpu(Np,Codeg);
  unsigned    *dcell     =SaveArrayGpu(Np,Dcellg);
  double2     *posxy     =SaveArrayGpu(Np,Posxyg);
  double      *posz      =SaveArrayGpu(Np,Poszg);
  float4      *velrhop   =SaveArrayGpu(Np,Velrhopg);
  float4      *velrhopm1 =SaveArrayGpu(Np,VelrhopM1g);
  double2     *posxypre  =SaveArrayGpu(Np,PosxyPreg);
  double      *poszpre   =SaveArrayGpu(Np,PoszPreg);
  float4      *velrhoppre=SaveArrayGpu(Np,VelrhopPreg);
  tsymatrix3f *spstau    =SaveArrayGpu(Np,SpsTaug);
  //-Frees pointers.
  ArraysGpu->Free(Idpg);
  ArraysGpu->Free(Codeg);
  ArraysGpu->Free(Dcellg);
  ArraysGpu->Free(Posxyg);
  ArraysGpu->Free(Poszg);
  ArraysGpu->Free(Velrhopg);
  ArraysGpu->Free(VelrhopM1g);
  ArraysGpu->Free(PosxyPreg);
  ArraysGpu->Free(PoszPreg);
  ArraysGpu->Free(VelrhopPreg);
  ArraysGpu->Free(SpsTaug);
  //-Resizes GPU memory allocation.
  const double mbparticle=(double(MemGpuParticles)/(1024*1024))/GpuParticlesSize; //-MB por particula.
  Log->Printf("**JSphGpu: Requesting gpu memory for %u particles: %.1f MB.",npnew,mbparticle*npnew);
  ArraysGpu->SetArraySize(npnew);
  //-Reserve pointers.
  Idpg    =ArraysGpu->ReserveUint();
  Codeg   =ArraysGpu->ReserveWord();
  Dcellg  =ArraysGpu->ReserveUint();
  Posxyg  =ArraysGpu->ReserveDouble2();
  Poszg   =ArraysGpu->ReserveDouble();
  Velrhopg=ArraysGpu->ReserveFloat4();
  if(velrhopm1) VelrhopM1g =ArraysGpu->ReserveFloat4();
  if(posxypre)  PosxyPreg  =ArraysGpu->ReserveDouble2();
  if(poszpre)   PoszPreg   =ArraysGpu->ReserveDouble();
  if(velrhoppre)VelrhopPreg=ArraysGpu->ReserveFloat4();
  if(spstau)    SpsTaug    =ArraysGpu->ReserveSymatrix3f();
  //-Restore data in GPU memory.
  RestoreArrayGpu(Np,idp,Idpg);
  RestoreArrayGpu(Np,code,Codeg);
  RestoreArrayGpu(Np,dcell,Dcellg);
  RestoreArrayGpu(Np,posxy,Posxyg);
  RestoreArrayGpu(Np,posz,Poszg);
  RestoreArrayGpu(Np,velrhop,Velrhopg);
  RestoreArrayGpu(Np,velrhopm1,VelrhopM1g);
  RestoreArrayGpu(Np,posxypre,PosxyPreg);
  RestoreArrayGpu(Np,poszpre,PoszPreg);
  RestoreArrayGpu(Np,velrhoppre,VelrhopPreg);
  RestoreArrayGpu(Np,spstau,SpsTaug);
  //-Updates values.
  GpuParticlesSize=npnew;
  MemGpuParticles=ArraysGpu->GetAllocMemoryGpu();
//�����������������������������������������������������������������������//MP
  if(TPhase==FLOW_Multi) {
    size_t multi=sizeof(StPhaseData)*MkListSize;
	MemGpuParticles+=multi;
  }
//�����������������������������������������������������������������������//MP
}

//==============================================================================
/// Saves a GPU array in CPU memory. 
//==============================================================================
template<class T> T* JSphGpu::TSaveArrayGpu(unsigned np,const T *datasrc)const{
  T *data=NULL;
  if(datasrc){
    try{
      data=new T[np];
    }
    catch(const std::bad_alloc){
      RunException("TSaveArrayGpu","Could not allocate the requested memory.");
    }
    cudaMemcpy(data,datasrc,sizeof(T)*np,cudaMemcpyDeviceToHost);
  }
  return(data);
}
//==============================================================================
unsigned* JSphGpu::SaveArrayGpu_Uint(unsigned np,const unsigned *datasrc)const{
  unsigned *data=NULL;
  if(datasrc){
    try{
      data=new unsigned[np];
    }
    catch(const std::bad_alloc){
      RunException("SaveArrayGpu_Uint","Could not allocate the requested memory.");
    }
    cudaMemcpy(data,datasrc,sizeof(unsigned)*np,cudaMemcpyDeviceToHost);
  }
  return(data);
}

//==============================================================================
/// Restores a GPU array from CPU memory. 
//==============================================================================
template<class T> void JSphGpu::TRestoreArrayGpu(unsigned np,T *data,T *datanew)const{
  if(data&&datanew)cudaMemcpy(datanew,data,sizeof(T)*np,cudaMemcpyHostToDevice);
  delete[] data;
}
//==============================================================================
void JSphGpu::RestoreArrayGpu_Uint(unsigned np,unsigned *data,unsigned *datanew)const{
  if(data&&datanew)cudaMemcpy(datanew,data,sizeof(unsigned)*np,cudaMemcpyHostToDevice);
  delete[] data;
}

//==============================================================================
/// Arrays para datos basicos de las particulas. 
/// Arrays for basic particle data.
//==============================================================================
void JSphGpu::ReserveBasicArraysGpu(){
  Idpg=ArraysGpu->ReserveUint();
  Codeg=ArraysGpu->ReserveWord();
  Dcellg=ArraysGpu->ReserveUint();
  Posxyg=ArraysGpu->ReserveDouble2();
  Poszg=ArraysGpu->ReserveDouble();
  Velrhopg=ArraysGpu->ReserveFloat4();
  if(TStep==STEP_Verlet)VelrhopM1g=ArraysGpu->ReserveFloat4();
  if(TVisco==VISCO_LaminarSPS)SpsTaug=ArraysGpu->ReserveSymatrix3f();
}

//==============================================================================
/// Devuelve la memoria reservada en cpu.
/// Returns the allocated memory on the CPU.
//==============================================================================
llong JSphGpu::GetAllocMemoryCpu()const{  
  llong s=JSph::GetAllocMemoryCpu();
  //Reservada en AllocMemoryParticles()
  //Allocated in AllocMemoryParticles()
  s+=MemCpuParticles;
  //Reservada en otros objetos
  //Allocated in other objects
  return(s);
}

//==============================================================================
/// Devuelve la memoria reservada en gpu.
/// Returns the allocated memory in the GPU.
//==============================================================================
llong JSphGpu::GetAllocMemoryGpu()const{  
  llong s=0;
  //Reservada en AllocGpuMemoryParticles()
  //Allocated in AllocGpuMemoryParticles()
  s+=MemGpuParticles;
  //Reservada en AllocGpuMemoryFixed()
  //Allocated in AllocGpuMemoryFixed()
  s+=MemGpuFixed;
  //Reservada en otros objetos
  //Allocated in ther objects
  return(s);
}

//==============================================================================
/// Visualiza la memoria reservada
/// Displays the allocated memory
//==============================================================================
void JSphGpu::PrintAllocMemory(llong mcpu,llong mgpu)const{
  Log->Printf("Allocated memory in CPU: %lld (%.2f MB)",mcpu,double(mcpu)/(1024*1024));
  Log->Printf("Allocated memory in GPU: %lld (%.2f MB)",mgpu,double(mgpu)/(1024*1024));
}

//==============================================================================
/// Copia constantes a la GPU.
/// Uploads constants to the GPU.
//==============================================================================
void JSphGpu::ConstantDataUp(){
  StCteInteraction ctes;
  memset(&ctes,0,sizeof(StCteInteraction));
  ctes.nbound=CaseNbound;
  ctes.massb=MassBound; ctes.massf=MassFluid;
  ctes.fourh2=Fourh2; ctes.h=H;
//�����������������������������������������������������������������������//MP
  ctes.cfl=CFLnumber;
//�����������������������������������������������������������������������//MP
  if(TKernel==KERNEL_Wendland){
    ctes.awen=Awen; ctes.bwen=Bwen;
  }
  else if(TKernel==KERNEL_Cubic){
    ctes.cubic_a1=CubicCte.a1; ctes.cubic_a2=CubicCte.a2; ctes.cubic_aa=CubicCte.aa; ctes.cubic_a24=CubicCte.a24;
    ctes.cubic_c1=CubicCte.c1; ctes.cubic_c2=CubicCte.c2; ctes.cubic_d1=CubicCte.d1; ctes.cubic_odwdeltap=CubicCte.od_wdeltap;
  }
  ctes.cs0=float(Cs0); ctes.eta2=Eta2;
  ctes.delta2h=Delta2H;
  ctes.scell=Scell; ctes.dosh=Dosh; ctes.dp=float(Dp);
  ctes.cteb=CteB; ctes.gamma=Gamma;
  ctes.rhopzero=RhopZero;
  ctes.ovrhopzero=1.f/RhopZero;
  ctes.movlimit=MovLimit;
  ctes.maprealposminx=MapRealPosMin.x; ctes.maprealposminy=MapRealPosMin.y; ctes.maprealposminz=MapRealPosMin.z;
  ctes.maprealsizex=MapRealSize.x; ctes.maprealsizey=MapRealSize.y; ctes.maprealsizez=MapRealSize.z;
  ctes.periactive=PeriActive;
  ctes.xperincx=PeriXinc.x; ctes.xperincy=PeriXinc.y; ctes.xperincz=PeriXinc.z;
  ctes.yperincx=PeriYinc.x; ctes.yperincy=PeriYinc.y; ctes.yperincz=PeriYinc.z;
  ctes.zperincx=PeriZinc.x; ctes.zperincy=PeriZinc.y; ctes.zperincz=PeriZinc.z;
  ctes.cellcode=DomCellCode;
  ctes.domposminx=DomPosMin.x; ctes.domposminy=DomPosMin.y; ctes.domposminz=DomPosMin.z;
//�����������������������������������������������������������������������//MP
  // - Calculation of the final cohesion coefficient
  ctes.shiftgrad.x=ShiftGrad.x;   ctes.shiftgrad.y=ShiftGrad.y;   ctes.shiftgrad.z=ShiftGrad.z;
  if(TPhase==FLOW_Multi){ 
	float rhop0max=0.f;
	ctes.phasecount=MkListSize;
	for(unsigned imp=0; imp<MkListSize; imp++){
		  rhop0max=((PhaseData[imp].PhaseRhop0>rhop0max)? PhaseData[imp].PhaseRhop0 : rhop0max);		
	}
	ctes.mpcoef=1.5f*9.81f*rhop0max*H*MPCoef; 
  }
//�����������������������������������������������������������������������//MP
  cusph::CteInteractionUp(&ctes);
  CheckCudaError("ConstantDataUp","Failed copying constants to GPU.");
}

//==============================================================================
/// Sube datos de particulas a la GPU.
/// Uploads particle data to the GPU.
//==============================================================================
void JSphGpu::ParticlesDataUp(unsigned n){
  cudaMemcpy(Idpg    ,Idp    ,sizeof(unsigned)*n,cudaMemcpyHostToDevice);
  cudaMemcpy(Codeg   ,Code   ,sizeof(word)*n    ,cudaMemcpyHostToDevice);
  cudaMemcpy(Dcellg  ,Dcell  ,sizeof(unsigned)*n,cudaMemcpyHostToDevice);
  cudaMemcpy(Posxyg  ,Posxy  ,sizeof(double2)*n ,cudaMemcpyHostToDevice);
  cudaMemcpy(Poszg   ,Posz   ,sizeof(double)*n  ,cudaMemcpyHostToDevice);
  cudaMemcpy(Velrhopg,Velrhop,sizeof(float4)*n  ,cudaMemcpyHostToDevice);
//�����������������������������������������������������������������������//MP
  if(TPhase==FLOW_Multi)cudaMemcpy(PhaseDatag,PhaseData,sizeof(StPhaseData)*MkListSize,cudaMemcpyHostToDevice);
//�����������������������������������������������������������������������//MP
  CheckCudaError("ParticlesDataUp","Failed copying data to GPU.");
}

//==============================================================================
/// Recupera datos de particulas de la GPU y devuelve el numero de particulas que
/// sera menor que n si se eliminaron las periodicas.
/// - code: Recupera datos de Codeg.
/// - cellorderdecode: Reordena componentes de pos y vel segun CellOrder.
/// - onlynormal: Solo se queda con las normales, elimina las particulas periodicas.
///
/// Recovers particle data from the GPU and returns the particle number that
/// are less than n if the paeriodic particles are removed
/// - code: Recovers data of Codeg
/// - cellorderdecode: Reordes position and velocity components according to CellOrder
/// - onlynormal: Onlly retains the normal particles, removes the periodic ones
//==============================================================================
unsigned JSphGpu::ParticlesDataDown(unsigned n,unsigned pini,bool code,bool cellorderdecode,bool onlynormal){
  unsigned num=n;
  cudaMemcpy(Idp,Idpg+pini,sizeof(unsigned)*n,cudaMemcpyDeviceToHost);
  cudaMemcpy(Posxy,Posxyg+pini,sizeof(double2)*n,cudaMemcpyDeviceToHost);
  cudaMemcpy(Posz,Poszg+pini,sizeof(double)*n,cudaMemcpyDeviceToHost);
  cudaMemcpy(Velrhop,Velrhopg+pini,sizeof(float4)*n,cudaMemcpyDeviceToHost);
  if(code || onlynormal)cudaMemcpy(Code,Codeg+pini,sizeof(word)*n,cudaMemcpyDeviceToHost);
  CheckCudaError("ParticlesDataDown","Failed copying data from GPU.");
  //-Elimina particulas no normales (periodicas y otras).
  //-Eliminates abnormal particles (periodic and others)
  if(onlynormal){
    unsigned ndel=0;
    for(unsigned p=0;p<n;p++){
      bool normal=(CODE_GetSpecialValue(Code[p])==CODE_NORMAL);
      if(ndel && normal){
        Idp[p-ndel]    =Idp[p];
        Posxy[p-ndel]  =Posxy[p];
        Posz[p-ndel]   =Posz[p];
        Velrhop[p-ndel]=Velrhop[p];
        Code[p-ndel]   =Code[p];
      }
      if(!normal)ndel++;
    }
    num-=ndel;
  }
  //-Convierte datos a formato simple.
  //-converts data to a simple format.
  for(unsigned p=0;p<n;p++){
    AuxPos[p]=TDouble3(Posxy[p].x,Posxy[p].y,Posz[p]);
    AuxVel[p]=TFloat3(Velrhop[p].x,Velrhop[p].y,Velrhop[p].z);
    AuxRhop[p]=Velrhop[p].w;
  }
  if(cellorderdecode)DecodeCellOrder(n,AuxPos,AuxVel);
  return(num);
}

//==============================================================================
/// Inicializa dispositivo cuda
/// Initialises CUDA device
//==============================================================================
void JSphGpu::SelecDevice(int gpuid){
  const char* met="SelecDevice";
  Log->Print("[Select CUDA Device]");
  GpuSelect=-1;
  int devcount;
  cudaGetDeviceCount(&devcount);
  CheckCudaError(met,"Failed getting devices info.");
  for(int dev=0;dev<devcount;dev++){
    cudaDeviceProp devp;
    cudaGetDeviceProperties(&devp,dev);
    Log->Printf("Device %d: \"%s\"",dev,devp.name);
    Log->Printf("  Compute capability:        %d.%d",devp.major,devp.minor);
    int corebymp=(devp.major==1? 8: (devp.major==2? (devp.minor==0? 32: 48): (devp.major==3? 192: -1)));
    Log->Printf("  Multiprocessors:           %d (%d cores)",devp.multiProcessorCount,devp.multiProcessorCount*corebymp);
    Log->Printf("  Memory global:             %d MB",int(devp.totalGlobalMem/(1024*1024)));
    Log->Printf("  Clock rate:                %.2f GHz",devp.clockRate*1e-6f);
    #if CUDART_VERSION >= 2020
    Log->Printf("  Run time limit on kernels: %s",(devp.kernelExecTimeoutEnabled? "Yes": "No"));
    #endif
    #if CUDART_VERSION >= 3010
    Log->Printf("  ECC support enabled:       %s",(devp.ECCEnabled? "Yes": "No"));
    #endif
  }
  Log->Print("");
  if(devcount){
    if(gpuid>=0)cudaSetDevice(gpuid);
    else{
      unsigned *ptr=NULL;
      cudaMalloc((void**)&ptr,sizeof(unsigned)*100);
      cudaFree(ptr);
    }
    cudaDeviceProp devp;
    int dev;
    cudaGetDevice(&dev);
    cudaGetDeviceProperties(&devp,dev);
    GpuSelect=dev;
    GpuName=devp.name;
    GpuGlobalMem=devp.totalGlobalMem;
    GpuSharedMem=int(devp.sharedMemPerBlock);
    GpuCompute=devp.major*10+devp.minor;
    //-Muestra informacion del hardware seleccionado.
    //-Displays information on the selected hardware.
    Log->Print("[GPU Hardware]");
    if(gpuid<0)Hardware=fun::PrintStr("Gpu_%d?=\"%s\"",GpuSelect,GpuName.c_str());
    else Hardware=fun::PrintStr("Gpu_%d=\"%s\"",GpuSelect,GpuName.c_str());
    if(gpuid<0)Log->Printf("Device default: %d  \"%s\"",GpuSelect,GpuName.c_str());
    else Log->Printf("Device selected: %d  \"%s\"",GpuSelect,GpuName.c_str());
    Log->Printf("Compute capability: %.1f",float(GpuCompute)/10);
    Log->Printf("Memory global: %d MB",int(GpuGlobalMem/(1024*1024)));
    Log->Printf("Memory shared: %u Bytes",GpuSharedMem);
  }
  //else RunException(met,"No hay dispositivos CUDA disponibles.");
  else RunException(met, "There are no available CUDA devices.");
}

//==============================================================================
/// Configures BlockSizeMode to compute optimum size of CUDA blocks.
//==============================================================================
void JSphGpu::ConfigBlockSizes(bool usezone,bool useperi){
  const char met[]="ConfigBlockSizes";
  //--------------------------------------
  Log->Print(" ");
  BlockSizesStr="";
  if(CellMode==CELLMODE_2H||CellMode==CELLMODE_H){
    const TpFtMode ftmode=(CaseNfloat? (UseDEM? FTMODE_Dem: FTMODE_Sph): FTMODE_None);
    const bool lamsps=(TVisco==VISCO_LaminarSPS);
    const bool shift=(TShifting!=SHIFT_None);
    BlockSizes.forcesbound=BlockSizes.forcesfluid=BlockSizes.forcesdem=BSIZE_FIXED;
    //-Collects kernel information.
    StKerInfo kerinfo;
    memset(&kerinfo,0,sizeof(StKerInfo));
    cusph::Interaction_Forces(Psimple,TKernel,(CaseNfloat>0),UseDEM,lamsps,TDeltaSph,CellMode,0,0,0,0,100,50,20,TUint3(0),NULL,TUint3(0),NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,TShifting,NULL,NULL,Simulate2D,&kerinfo,NULL);
    if(UseDEM)cusph::Interaction_ForcesDem(Psimple,CellMode,BlockSizes.forcesdem,CaseNfloat,TUint3(0),NULL,TUint3(0),NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,&kerinfo);
    //Log->Printf("====> bound -> r:%d  bs:%d  bsmax:%d",kerinfo.forcesbound_rg,kerinfo.forcesbound_bs,kerinfo.forcesbound_bsmax);
    //Log->Printf("====> fluid -> r:%d  bs:%d  bsmax:%d",kerinfo.forcesfluid_rg,kerinfo.forcesfluid_bs,kerinfo.forcesfluid_bsmax);
    //Log->Printf("====> dem   -> r:%d  bs:%d  bsmax:%d",kerinfo.forcesdem_rg,kerinfo.forcesdem_bs,kerinfo.forcesdem_bsmax);
    //-Defines blocsize according BlockSizeMode.
    if(BlockSizeMode==BSIZEMODE_Occupancy){
      if(!kerinfo.forcesbound_bs || !kerinfo.forcesfluid_bs){
        Log->Printf("**BlockSize calculation mode %s is invalid.",GetNameBlockSizeMode(BlockSizeMode));
        BlockSizeMode=BSIZEMODE_Fixed;
      }
      else{
        if(kerinfo.forcesbound_bs)BlockSizes.forcesbound=kerinfo.forcesbound_bs;
        if(kerinfo.forcesfluid_bs)BlockSizes.forcesfluid=kerinfo.forcesfluid_bs;
        if(kerinfo.forcesdem_bs)BlockSizes.forcesdem=kerinfo.forcesdem_bs;
      }
    }
    if(BlockSizeMode==BSIZEMODE_Empirical){
      BsAuto=new JBlockSizeAuto(Log,500);
      BsAuto->AddKernel("KerInteractionForcesFluid",64,31,32,BSIZE_FIXED);  //15:512 31:1024
      BsAuto->AddKernel("KerInteractionForcesBound",64,31,32,BSIZE_FIXED);
      BsAuto->AddKernel("KerInteractionForcesDem",64,31,32,BSIZE_FIXED);
      if(kerinfo.forcesdem_bs)BlockSizes.forcesdem=kerinfo.forcesdem_bs;
    }
    Log->Printf("BlockSize calculation mode: %s.",GetNameBlockSizeMode(BlockSizeMode));
    string txrb=(kerinfo.forcesbound_rg? fun::PrintStr("(%d regs)",kerinfo.forcesbound_rg): string("(? regs)"));
    string txrf=(kerinfo.forcesbound_rg? fun::PrintStr("(%d regs)",kerinfo.forcesfluid_rg): string("(? regs)"));
    string txrd=(kerinfo.forcesdem_rg  ? fun::PrintStr("(%d regs)",kerinfo.forcesdem_rg  ): string("(? regs)"));
    string txb=string("BsForcesBound=")+(BlockSizeMode==BSIZEMODE_Empirical? string("Dynamic"): fun::IntStr(BlockSizes.forcesbound))+" "+txrb;
    string txf=string("BsForcesFluid=")+(BlockSizeMode==BSIZEMODE_Empirical? string("Dynamic"): fun::IntStr(BlockSizes.forcesfluid))+" "+txrf;
    string txd=string("BsForcesDem="  )+fun::IntStr(BlockSizes.forcesdem)+" "+txrd;
    Log->Print(string("  ")+txb);
    Log->Print(string("  ")+txf);
    if(UseDEM)Log->Print(string("  ")+txd);
    if(!BlockSizesStr.empty())BlockSizesStr=BlockSizesStr+", ";
    BlockSizesStr=BlockSizesStr+txb+", "+txf;
    if(UseDEM)BlockSizesStr=BlockSizesStr+", "+txd;
  }
  else RunException(met,"CellMode unrecognised.");
  Log->Print(" ");
}

//==============================================================================
/// Configura modo de ejecucion en GPU.
/// Configures execution mode in the GPU
//==============================================================================
void JSphGpu::ConfigRunMode(std::string preinfo){
  #ifndef WIN32
    const int len=128; char hname[len];
    gethostname(hname,len);
    if(!preinfo.empty())preinfo=preinfo+", ";
    preinfo=preinfo+"HostName:"+hname;
  #endif
  RunMode=preinfo+RunMode;
  if(Stable)RunMode=string("Stable, ")+RunMode;
  if(Psimple)RunMode=string("Pos-Simple, ")+RunMode;
  else RunMode=string("Pos-Double, ")+RunMode;
  Log->Print(fun::VarStr("RunMode",RunMode));
  if(!RunMode.empty())RunMode=RunMode+", "+BlockSizesStr;
}

//==============================================================================
/// Adjusts variables of particles of floating bodies.
//==============================================================================
void JSphGpu::InitFloating(){
  if(PartBegin){
    JPartFloatBi4Load ftdata;
    ftdata.LoadFile(PartBeginDir);
    //-Comprueba coincidencia de datos constantes.
    //-Checks if the constant data match.
    for(unsigned cf=0;cf<FtCount;cf++)ftdata.CheckHeadData(cf,FtObjs[cf].mkbound,FtObjs[cf].begin,FtObjs[cf].count,FtObjs[cf].mass);
    //-Carga datos de PART.
    //-Loads PART data.
    ftdata.LoadPart(PartBegin);
    for(unsigned cf=0;cf<FtCount;cf++){
      FtObjs[cf].center=OrderCodeValue(CellOrder,ftdata.GetPartCenter(cf));
      FtObjs[cf].fvel=OrderCodeValue(CellOrder,ftdata.GetPartFvel(cf));
      FtObjs[cf].fomega=OrderCodeValue(CellOrder,ftdata.GetPartFomega(cf));
      FtObjs[cf].radius=ftdata.GetHeadRadius(cf);
    }
    DemDtForce=ftdata.GetPartDemDtForce();
  }
  //-Copies massp values to GPU.
  {
    float *massp=new float[FtCount];
    for(unsigned cf=0;cf<FtCount;cf++)massp[cf]=FtObjs[cf].massp;
    cudaMemcpy(FtoMasspg,massp,sizeof(float)*FtCount,cudaMemcpyHostToDevice);
    delete[] massp;
  }
  //-Copies floating values to GPU.
  {
    typedef struct{
      unsigned pini;
      unsigned np;
      float radius;
      float mass;
    }stdata;

    stdata *data=new stdata[FtCount];
    tdouble3 *center=new tdouble3[FtCount];
    tfloat3 *vel=new tfloat3[FtCount];
    tfloat3 *omega=new tfloat3[FtCount];
    for(unsigned cf=0;cf<FtCount;cf++){
      data[cf].pini=FtObjs[cf].begin-CaseNpb;
      data[cf].np=FtObjs[cf].count;
      data[cf].radius=FtObjs[cf].radius;
      data[cf].mass=FtObjs[cf].mass;
      //float pini,np;   //-Daba problemas en Linux... //-Gives problems in Linux
      //*((unsigned*)&pini)=FtObjs[cf].begin-CaseNpb;
      //*((unsigned*)&np  )=FtObjs[cf].count;
      //data[cf]=TFloat4(pini,np,FtObjs[cf].radius,FtObjs[cf].mass);
      center[cf]=FtObjs[cf].center;
      vel[cf]=FtObjs[cf].fvel;
      omega[cf]=FtObjs[cf].fomega;
    }
    cudaMemcpy(FtoDatag  ,data  ,sizeof(float4) *FtCount,cudaMemcpyHostToDevice);
    cudaMemcpy(FtoCenterg,center,sizeof(double3)*FtCount,cudaMemcpyHostToDevice);
    cudaMemcpy(FtoVelg   ,vel   ,sizeof(float3) *FtCount,cudaMemcpyHostToDevice);
    cudaMemcpy(FtoOmegag ,omega ,sizeof(float3) *FtCount,cudaMemcpyHostToDevice);
    delete[] data;
    delete[] center;
    delete[] vel;
    delete[] omega;
  }
  //-Copies data object for DEM to GPU.
  if(UseDEM){ //(DEM)
    float4 *data=new float4[DemObjsSize];
    for(unsigned c=0;c<DemObjsSize;c++){
      data[c].x=DemObjs[c].mass;
      data[c].y=DemObjs[c].tau;
      data[c].z=DemObjs[c].kfric;
      data[c].w=DemObjs[c].restitu;
    }
    cudaMemcpy(DemDatag,data,sizeof(float4)*DemObjsSize,cudaMemcpyHostToDevice);
    delete[] data;
  }
}

//==============================================================================
/// Inicializa vectores y variables para la ejecucion.
/// initialises arrays and variables for the execution.
//==============================================================================
void JSphGpu::InitRun(){
  const char met[]="InitRun";
  WithFloating=(CaseNfloat>0);
  if(TStep==STEP_Verlet){
    cudaMemcpy(VelrhopM1g,Velrhopg,sizeof(float4)*Np,cudaMemcpyDeviceToDevice);
    VerletStep=0;
  }
  else if(TStep==STEP_Symplectic)DtPre=DtIni;
  if(TVisco==VISCO_LaminarSPS)cudaMemset(SpsTaug,0,sizeof(tsymatrix3f)*Np);
  if(UseDEM)DemDtForce=DtIni; //(DEM)
  if(CaseNfloat)InitFloating();

  //-Adjust paramaters to start.
  PartIni=PartBeginFirst;
  TimeStepIni=(!PartIni? 0: PartBeginTimeStep);
  //-Adjust motion for the instant of the loaded PART.
  if(CaseNmoving){
    MotionTimeMod=(!PartIni? PartBeginTimeStep: 0);
    Motion->ProcesTime(0,TimeStepIni+MotionTimeMod);
  }

  //-Uses Inlet information from PART readed.
  if(PartBeginTimeStep && PartBeginTotalNp){
    TotalNp=PartBeginTotalNp;
    IdMax=unsigned(TotalNp-1);
  }

  //-Prepares WaveGen configuration.
  if(WaveGen){
    Log->Print("\nWave paddles configuration:");
    WaveGen->Init(TimeMax,Gravity,Simulate2D,CellOrder,MassFluid,Dp,Dosh,Scell,Hdiv,DomPosMin,DomRealPosMin,DomRealPosMax);
    WaveGen->VisuConfig(""," ");
  }

  //-Prepares AccInput configuration.
  if(AccInput){
    Log->Print("\nAccInput configuration:");
    AccInput->Init(TimeMax);
    AccInput->VisuConfig(""," ");
  }

  //-Process Special configurations in XML.
  JXml xml; xml.LoadFile(FileXml);

  //-Configuration of SaveDt.
  if(xml.GetNode("case.execution.special.savedt",false)){
    SaveDt=new JSaveDt(Log);
    SaveDt->Config(&xml,"case.execution.special.savedt",TimeMax,TimePart);
    SaveDt->VisuConfig("\nSaveDt configuration:"," ");
  }

  //-Shows configuration of JTimeOut.
  if(TimeOut->UseSpecialConfig())TimeOut->VisuConfig(Log,"\nTimeOut configuration:"," ");

  Part=PartIni; Nstep=0; PartNstep=0; PartOut=0;
  TimeStep=TimeStepIni; TimeStepM1=TimeStep;
  if(DtFixed)DtIni=DtFixed->GetDt(TimeStep,DtIni);
  TimePartNext=TimeOut->GetNextTime(TimeStep);
  CheckCudaError("InitRun","Failed initializing variables for execution.");
}

//==============================================================================
/// Adds variable acceleration from input files.
//==============================================================================
void JSphGpu::AddAccInput(){
  for(unsigned c=0;c<AccInput->GetCount();c++){
    unsigned mkfluid;
    tdouble3 acclin,accang,centre,velang,vellin;
    bool setgravity;
    AccInput->GetAccValues(c,TimeStep,mkfluid,acclin,accang,centre,velang,vellin,setgravity);
    const word codesel=word(mkfluid);
    cusph::AddAccInput(Np-Npb,Npb,codesel,acclin,accang,centre,velang,vellin,setgravity,Gravity,Codeg,Posxyg,Poszg,Velrhopg,Aceg);
  }
}

//==============================================================================
/// Prepara variables para interaccion "INTER_Forces" o "INTER_ForcesCorr".
/// Prepares variables for interaction "INTER_Forces" or "INTER_ForcesCorr".
//==============================================================================
void JSphGpu::PreInteractionVars_Forces(TpInter tinter,unsigned np,unsigned npb){
  //-Inicializa arrays.
  //-Initialises arrays.
  const unsigned npf=np-npb;
  cudaMemset(ViscDtg,0,sizeof(float)*np);                                //ViscDtg[]=0
  cudaMemset(Arg,0,sizeof(float)*np);                                    //Arg[]=0
  if(Deltag)cudaMemset(Deltag,0,sizeof(float)*np);                       //Deltag[]=0
  if(ShiftPosg)cudaMemset(ShiftPosg,0,sizeof(tfloat3)*np);               //ShiftPosg[]=0
  if(ShiftDetectg)cudaMemset(ShiftDetectg,1,sizeof(float)*np);           //ShiftDetectg[]=0
  cudaMemset(Aceg,0,sizeof(tfloat3)*npb);                                //Aceg[]=(0,0,0) para bound //Aceg[]=(0,0,0) for the boundary
  cusph::InitArray(npf,Aceg+npb,Gravity);                                //Aceg[]=Gravity para fluid //Aceg[]=Gravity for the fluid
  if(SpsGradvelg)cudaMemset(SpsGradvelg+npb,0,sizeof(tsymatrix3f)*npf);  //SpsGradvelg[]=(0,0,0,0,0,0).
//�����������������������������������������������������������������������//MP
  if(SurfCoef)cudaMemset(Surfg+npb,0,sizeof(tsymatrix3f)*npf);			 //Surfg[]=(0,0,0,0,0,0).
//�����������������������������������������������������������������������//MP

  //-Apply the extra forces to the correct particle sets.
  if(AccInput)AddAccInput();
}

//==============================================================================
/// Prepara variables para interaccion "INTER_Forces" o "INTER_ForcesCorr".
/// Prepares variables for interaction "INTER_Forces" or "INTER_ForcesCorr".
//==============================================================================
void JSphGpu::PreInteraction_Forces(TpInter tinter){
  TmgStart(Timers,TMG_CfPreForces);
  //-Asigna memoria.
  //-Allocates memory.
  ViscDtg=ArraysGpu->ReserveFloat();
  Arg=ArraysGpu->ReserveFloat();
  Aceg=ArraysGpu->ReserveFloat3();
  if(TDeltaSph==DELTA_DynamicExt)Deltag=ArraysGpu->ReserveFloat();
  if(TShifting!=SHIFT_None){
    ShiftPosg=ArraysGpu->ReserveFloat3();
    if(ShiftTFS)ShiftDetectg=ArraysGpu->ReserveFloat();
  }   
  if(TVisco==VISCO_LaminarSPS)SpsGradvelg=ArraysGpu->ReserveSymatrix3f();

  //-Prepara datos para interaccion Pos-Simple.
  //-Prepares data for interation Pos-Simple.
  if(Psimple){
    PsPospressg=ArraysGpu->ReserveFloat4();
    cusph::PreInteractionSimple(Np,Posxyg,Poszg,Velrhopg,PsPospressg,CteB,Gamma);
  }
  //-Inicializa arrays.
  //-Initialises arrays.
  PreInteractionVars_Forces(tinter,Np,Npb);

  //-Calcula VelMax: Se incluyen las particulas floatings y no afecta el uso de condiciones periodicas.
  //-Computes VelMax: Includes the particles from floating bodies and does not affect the periodic conditions.
  const unsigned pini=(DtAllParticles? 0: Npb);
  cusph::ComputeVelMod(Np-pini,Velrhopg+pini,ViscDtg);
  float velmax=cusph::ReduMaxFloat(Np-pini,0,ViscDtg,CellDiv->GetAuxMem(cusph::ReduMaxFloatSize(Np-pini)));
  VelMax=sqrt(velmax);
  cudaMemset(ViscDtg,0,sizeof(float)*Np);           //ViscDtg[]=0
  ViscDtMax=0;
  CheckCudaError("PreInteraction_Forces","Failed calculating VelMax.");
  TmgStop(Timers,TMG_CfPreForces);
}

//�����������������������������������������������������������������������//MP
//==============================================================================
/// Prepara variables para interaccion "INTER_Forces" o "INTER_ForcesCorr".
/// Prepares variables for interaction "INTER_Forces" or "INTER_ForcesCorr". -��//MP
//==============================================================================
void JSphGpu::PreInteraction_ForcesMP(TpInter tinter){
  TmgStart(Timers,TMG_CfPreForces);
  //-Asigna memoria.
  //-Allocates memory.
  ViscDtg=ArraysGpu->ReserveFloat();
  Arg=ArraysGpu->ReserveFloat();
  Aceg=ArraysGpu->ReserveFloat3();
  if(TDeltaSph==DELTA_DynamicExt)Deltag=ArraysGpu->ReserveFloat();
  if(TShifting!=SHIFT_None){
    ShiftPosg=ArraysGpu->ReserveFloat3();
    /*if(ShiftTFS)*/ShiftDetectg=ArraysGpu->ReserveFloat();
  }   
  if(TVisco==VISCO_LaminarSPS)SpsGradvelg=ArraysGpu->ReserveSymatrix3f();
  if(SurfCoef)Surfg=ArraysGpu->ReserveSymatrix3f();

  //-Prepara datos para interaccion Pos-Simple.
  //-Prepares data for interation Pos-Simple.
  if(Psimple){
    PsPospressg=ArraysGpu->ReserveFloat4();
	cusph::PreInteractionSimpleMP(Np,Posxyg,Poszg,Velrhopg,PsPospressg,Codeg,PhaseDatag,MkListSize);
  }
  //-Inicializa arrays.
  //-Initialises arrays.
  PreInteractionVars_Forces(tinter,Np,Npb);

  //-Calcula VelMax: Se incluyen las particulas floatings y no afecta el uso de condiciones periodicas.
  //-Computes VelMax: Includes the particles from floating bodies and does not affect the periodic conditions.
  const unsigned pini=(DtAllParticles? 0: Npb);
  cusph::ComputeVelMod(Np-pini,Velrhopg+pini,ViscDtg);
  float velmax=cusph::ReduMaxFloat(Np-pini,0,ViscDtg,CellDiv->GetAuxMem(cusph::ReduMaxFloatSize(Np-pini)));
  VelMax=sqrt(velmax);
  cudaMemset(ViscDtg,0,sizeof(float)*Np);           //ViscDtg[]=0
  ViscDtMax=0;
  CheckCudaError("PreInteraction_Forces","Failed calculating VelMax.");
  TmgStop(Timers,TMG_CfPreForces);
}
//�����������������������������������������������������������������������//MP

//==============================================================================
/// Libera memoria asignada de ArraysGpu.
/// Releases memory allocated for ArraysGpu.
//==============================================================================
void JSphGpu::PosInteraction_Forces(){
  //-Libera memoria asignada en PreInteraction_Forces().
  //-Releases memory allocated in PreInteraction_Forces().
  ArraysGpu->Free(Arg);          Arg=NULL;
  ArraysGpu->Free(Aceg);         Aceg=NULL;
  ArraysGpu->Free(ViscDtg);      ViscDtg=NULL;
  ArraysGpu->Free(Deltag);       Deltag=NULL;
  ArraysGpu->Free(ShiftPosg);    ShiftPosg=NULL;
  ArraysGpu->Free(ShiftDetectg); ShiftDetectg=NULL;
  ArraysGpu->Free(PsPospressg);  PsPospressg=NULL;
  ArraysGpu->Free(SpsGradvelg);  SpsGradvelg=NULL;
//�����������������������������������������������������������������������//MP
  ArraysGpu->Free(Surfg);		 Surfg=NULL;
//�����������������������������������������������������������������������//MP
}

//==============================================================================
/// Actualizacion de particulas segun fuerzas y dt usando Verlet.
/// Updates particles according to forces and dt using Verlet.
//==============================================================================
void JSphGpu::ComputeVerlet(double dt){  //pdtedom
  TmgStart(Timers,TMG_SuComputeStep);
  const bool shift=TShifting!=SHIFT_None;
  VerletStep++;
  //-Asigna memoria para calcular el desplazamiento.
  //-Allocates memory to compute the displacement.
  double2 *movxyg=ArraysGpu->ReserveDouble2();
  double *movzg=ArraysGpu->ReserveDouble();
  //-Calcula desplazamiento, velocidad y densidad.
  //-computes displacement, velocity and density.
  if(VerletStep<VerletSteps){
    const double twodt=dt+dt;
    cusph::ComputeStepVerlet(WithFloating,shift,Np,Npb,Velrhopg,VelrhopM1g,Arg,Aceg,ShiftPosg,dt,twodt,RhopOutMin,RhopOutMax,Codeg,movxyg,movzg,VelrhopM1g);
  }
  else{
    cusph::ComputeStepVerlet(WithFloating,shift,Np,Npb,Velrhopg,Velrhopg,Arg,Aceg,ShiftPosg,dt,dt,RhopOutMin,RhopOutMax,Codeg,movxyg,movzg,VelrhopM1g);
    VerletStep=0;
  }
  //-Los nuevos valores se calculan en VelrhopM1g.
  //-The new values are calculated in VelRhopM1g.
  swap(Velrhopg,VelrhopM1g);   //-Intercambia Velrhopg y VelrhopM1g. //-Exchanges Velrhopg and VelrhopM1g
  //-Aplica desplazamiento a las particulas fluid no periodicas.
  //-Applies displacement to non-periodic fluid particles.
  cusph::ComputeStepPos(PeriActive,WithFloating,Np,Npb,movxyg,movzg,Posxyg,Poszg,Dcellg,Codeg);
  //-Libera memoria asignada al desplazamiento.
  //-Releases memory allocated for the diplacement.
  ArraysGpu->Free(movxyg);   movxyg=NULL;
  ArraysGpu->Free(movzg);    movzg=NULL;
  TmgStop(Timers,TMG_SuComputeStep);
}

//�����������������������������������������������������������������������//MP
//==============================================================================
/// Updates particles according to forces and dt using Verlet. Used for multi-phase flows. -��//MP
//==============================================================================
void JSphGpu::ComputeVerletMP(double dt){  //pdtedom
  TmgStart(Timers,TMG_SuComputeStep);
  const bool shift=TShifting!=SHIFT_None;
  VerletStep++;
  //-Asigna memoria para calcular el desplazamiento.
  //-Allocates memory to compute the displacement.
  double2 *movxyg=ArraysGpu->ReserveDouble2();
  double *movzg=ArraysGpu->ReserveDouble();
  //-Calcula desplazamiento, velocidad y densidad.
  //-computes displacement, velocity and density.
  if(VerletStep<VerletSteps){
    const double twodt=dt+dt;
    cusph::ComputeStepVerletMP(WithFloating,shift,Np,Npb,Velrhopg,VelrhopM1g,Arg,Aceg,ShiftPosg,dt,twodt,RhopOutMin,RhopOutMax,Codeg,movxyg,movzg,VelrhopM1g,MkListSize,PhaseDatag);
  }
  else{
    cusph::ComputeStepVerletMP(WithFloating,shift,Np,Npb,Velrhopg,Velrhopg  ,Arg,Aceg,ShiftPosg,dt,   dt,RhopOutMin,RhopOutMax,Codeg,movxyg,movzg,VelrhopM1g,MkListSize,PhaseDatag);
    VerletStep=0;
  }
  //-Los nuevos valores se calculan en VelrhopM1g.
  //-The new values are calculated in VelRhopM1g.
  swap(Velrhopg,VelrhopM1g);   //-Intercambia Velrhopg y VelrhopM1g. //-Exchanges Velrhopg and VelrhopM1g
  //-Aplica desplazamiento a las particulas fluid no periodicas.
  //-Applies displacement to non-periodic fluid particles.
  cusph::ComputeStepPos(PeriActive,WithFloating,Np,Npb,movxyg,movzg,Posxyg,Poszg,Dcellg,Codeg);
  //-Libera memoria asignada al desplazamiento.
  //-Releases memory allocated for the diplacement.
  ArraysGpu->Free(movxyg);   movxyg=NULL;
  ArraysGpu->Free(movzg);    movzg=NULL;
  TmgStop(Timers,TMG_SuComputeStep);
}
//�����������������������������������������������������������������������//MP

//==============================================================================
/// Actualizacion de particulas segun fuerzas y dt usando Symplectic-Predictor.
/// Updates particles according to forces and dt using Symplectic-Predictor.
//==============================================================================
void JSphGpu::ComputeSymplecticPre(double dt){
  TmgStart(Timers,TMG_SuComputeStep);
  const bool shift=TShifting!=SHIFT_None;
  //-Asigna memoria a variables Pre.
  //-Allocates memory to predictor variables.
  PosxyPreg=ArraysGpu->ReserveDouble2();
  PoszPreg=ArraysGpu->ReserveDouble();
  VelrhopPreg=ArraysGpu->ReserveFloat4();
  //-Cambia datos a variables Pre para calcular nuevos datos.
  //-Changes data of predictor variables for calculating the new data
  swap(PosxyPreg,Posxyg);      //Es decir... PosxyPre[] <= Posxy[] //i.e. PosxyPre[] <= Posxy[]
  swap(PoszPreg,Poszg);        //Es decir... PoszPre[] <= Posz[] //i.e. PoszPre[] <= Posz[]
  swap(VelrhopPreg,Velrhopg);  //Es decir... VelrhopPre[] <= Velrhop[] //i.e. VelrhopPre[] <= Velrhop[]
  //-Asigna memoria para calcular el desplazamiento.
  //-Allocate memory to compute the diplacement
  double2 *movxyg=ArraysGpu->ReserveDouble2();
  double *movzg=ArraysGpu->ReserveDouble();
  //-Calcula desplazamiento, velocidad y densidad.
  //-Compute displacement, velocity and density.
  const double dt05=dt*.5;
  cusph::ComputeStepSymplecticPre(WithFloating,shift,Np,Npb,VelrhopPreg,Arg,Aceg,ShiftPosg,dt05,RhopOutMin,RhopOutMax,Codeg,movxyg,movzg,Velrhopg);
  //-Aplica desplazamiento a las particulas fluid no periodicas.
  //-Applies displacement to non-periodic fluid particles.
  cusph::ComputeStepPos2(PeriActive,WithFloating,Np,Npb,PosxyPreg,PoszPreg,movxyg,movzg,Posxyg,Poszg,Dcellg,Codeg);
  //-Libera memoria asignada al desplazamiento.
  //-Releases memory allocated for the displacement
  ArraysGpu->Free(movxyg);   movxyg=NULL;
  ArraysGpu->Free(movzg);    movzg=NULL;
  //-Copia posicion anterior del contorno.
  //-Copies previous position of the boundaries.
  cudaMemcpy(Posxyg,PosxyPreg,sizeof(double2)*Npb,cudaMemcpyDeviceToDevice);
  cudaMemcpy(Poszg,PoszPreg,sizeof(double)*Npb,cudaMemcpyDeviceToDevice);
  TmgStop(Timers,TMG_SuComputeStep);
}

//�����������������������������������������������������������������������//MP
//==============================================================================
/// Actualizacion de particulas segun fuerzas y dt usando Symplectic-Predictor.
/// Updates particles according to forces and dt using Symplectic-Predictor. -��//MP
//==============================================================================
void JSphGpu::ComputeSymplecticPreMP(double dt){
  TmgStart(Timers,TMG_SuComputeStep);
  const bool shift=TShifting!=SHIFT_None;
  //-Asigna memoria a variables Pre.
  //-Allocates memory to predictor variables.
  PosxyPreg=ArraysGpu->ReserveDouble2();
  PoszPreg=ArraysGpu->ReserveDouble();
  VelrhopPreg=ArraysGpu->ReserveFloat4();
  //-Cambia datos a variables Pre para calcular nuevos datos.
  //-Changes data of predictor variables for calculating the new data
  swap(PosxyPreg,Posxyg);      //Es decir... PosxyPre[] <= Posxy[] //i.e. PosxyPre[] <= Posxy[]
  swap(PoszPreg,Poszg);        //Es decir... PoszPre[] <= Posz[] //i.e. PoszPre[] <= Posz[]
  swap(VelrhopPreg,Velrhopg);  //Es decir... VelrhopPre[] <= Velrhop[] //i.e. VelrhopPre[] <= Velrhop[]
  //-Asigna memoria para calcular el desplazamiento.
  //-Allocate memory to compute the diplacement
  double2 *movxyg=ArraysGpu->ReserveDouble2();
  double *movzg=ArraysGpu->ReserveDouble();
  //-Calcula desplazamiento, velocidad y densidad.
  //-Compute displacement, velocity and density.
  const double dt05=dt*.5;
  cusph::ComputeStepSymplecticPreMP(WithFloating,shift,Np,Npb,VelrhopPreg,Arg,Aceg,ShiftPosg,dt05,RhopOutMin,RhopOutMax,Codeg,movxyg,movzg,Velrhopg,MkListSize,PhaseDatag);
  //-Aplica desplazamiento a las particulas fluid no periodicas.
  //-Applies displacement to non-periodic fluid particles.
  cusph::ComputeStepPos2(PeriActive,WithFloating,Np,Npb,PosxyPreg,PoszPreg,movxyg,movzg,Posxyg,Poszg,Dcellg,Codeg);
  //-Libera memoria asignada al desplazamiento.
  //-Releases memory allocated for the displacement
  ArraysGpu->Free(movxyg);   movxyg=NULL;
  ArraysGpu->Free(movzg);    movzg=NULL;
  //-Copia posicion anterior del contorno.
  //-Copies previous position of the boundaries.
  cudaMemcpy(Posxyg,PosxyPreg,sizeof(double2)*Npb,cudaMemcpyDeviceToDevice);
  cudaMemcpy(Poszg,PoszPreg,sizeof(double)*Npb,cudaMemcpyDeviceToDevice);
  TmgStop(Timers,TMG_SuComputeStep);
}
//�����������������������������������������������������������������������//MP


//==============================================================================
/// Actualizacion de particulas segun fuerzas y dt usando Symplectic-Corrector.
/// Updates particles according to forces and dt using Symplectic-Corrector.
//==============================================================================
void JSphGpu::ComputeSymplecticCorr(double dt){
  TmgStart(Timers,TMG_SuComputeStep);
  const bool shift=TShifting!=SHIFT_None;
  //-Asigna memoria para calcular el desplazamiento.
  //-Allocates memory to calculate the displacement.
  double2 *movxyg=ArraysGpu->ReserveDouble2();
  double *movzg=ArraysGpu->ReserveDouble();
  //-Calcula desplazamiento, velocidad y densidad.
  //-Computes displacement, velocity and density.
  const double dt05=dt*.5;
  cusph::ComputeStepSymplecticCor(WithFloating,shift,Np,Npb,VelrhopPreg,Arg,Aceg,ShiftPosg,dt05,dt,RhopOutMin,RhopOutMax,Codeg,movxyg,movzg,Velrhopg);
  //-Aplica desplazamiento a las particulas fluid no periodicas.
  //-Applies displacement to non-periodic fluid particles.
  cusph::ComputeStepPos2(PeriActive,WithFloating,Np,Npb,PosxyPreg,PoszPreg,movxyg,movzg,Posxyg,Poszg,Dcellg,Codeg);
  //-Libera memoria asignada al desplazamiento.
  //-Releases memory allocated for diplacement.
  ArraysGpu->Free(movxyg);   movxyg=NULL;
  ArraysGpu->Free(movzg);    movzg=NULL;
  //-Libera memoria asignada a variables Pre en ComputeSymplecticPre().
  //-Releases memory allocated for the predictor variables in ComputeSymplecticPre().
  ArraysGpu->Free(PosxyPreg);    PosxyPreg=NULL;
  ArraysGpu->Free(PoszPreg);     PoszPreg=NULL;
  ArraysGpu->Free(VelrhopPreg);  VelrhopPreg=NULL;
  TmgStop(Timers,TMG_SuComputeStep);
}

//�����������������������������������������������������������������������//MP
//==============================================================================
/// Actualizacion de particulas segun fuerzas y dt usando Symplectic-Corrector.
/// Updates particles according to forces and dt using Symplectic-Corrector. -��//MP
//==============================================================================
void JSphGpu::ComputeSymplecticCorrMP(double dt){
  TmgStart(Timers,TMG_SuComputeStep);
  const bool shift=TShifting!=SHIFT_None;
  //-Asigna memoria para calcular el desplazamiento.
  //-Allocates memory to calculate the displacement.
  double2 *movxyg=ArraysGpu->ReserveDouble2();
  double *movzg=ArraysGpu->ReserveDouble();
  //-Calcula desplazamiento, velocidad y densidad.
  //-Computes displacement, velocity and density.
  const double dt05=dt*.5;
  cusph::ComputeStepSymplecticCorMP(WithFloating,shift,Np,Npb,VelrhopPreg,Arg,Aceg,ShiftPosg,dt05,dt,RhopOutMin,RhopOutMax,Codeg,movxyg,movzg,Velrhopg,MkListSize,PhaseDatag);
  //-Aplica desplazamiento a las particulas fluid no periodicas.
  //-Applies displacement to non-periodic fluid particles.
  cusph::ComputeStepPos2(PeriActive,WithFloating,Np,Npb,PosxyPreg,PoszPreg,movxyg,movzg,Posxyg,Poszg,Dcellg,Codeg);
  //-Libera memoria asignada al desplazamiento.
  //-Releases memory allocated for diplacement.
  ArraysGpu->Free(movxyg);   movxyg=NULL;
  ArraysGpu->Free(movzg);    movzg=NULL;
  //-Libera memoria asignada a variables Pre en ComputeSymplecticPre().
  //-Releases memory allocated for the predictor variables in ComputeSymplecticPre().
  ArraysGpu->Free(PosxyPreg);    PosxyPreg=NULL;
  ArraysGpu->Free(PoszPreg);     PoszPreg=NULL;
  ArraysGpu->Free(VelrhopPreg);  VelrhopPreg=NULL;
  TmgStop(Timers,TMG_SuComputeStep);
}
//�����������������������������������������������������������������������//MP

//==============================================================================
/// Calcula un Dt variable.
/// Computes the variable Dt.
//==============================================================================
double JSphGpu::DtVariable(bool final){
  //-dt1 depends on force per unit mass.
  const double acemax=sqrt(double(AceMax));
  const double dt1=(AceMax? (sqrt(double(H)/AceMax)): DBL_MAX); 
  //-dt2 combines the Courant and the viscous time-step controls.
//�����������������������������������������������������������������������//MP
  //-Find maximum speed of sound among phases
  float cs0max=float(Cs0);
  if(TPhase==FLOW_Multi){
	for(unsigned ipres=0; ipres<MkListSize; ipres++) cs0max=((PhaseData[ipres].PhaseCs0>cs0max)? PhaseData[ipres].PhaseCs0 : cs0max);
  }
  const double dt2=double(H)/(max(double(cs0max),VelMax*10.)+double(H)*ViscDtMax);
  //-Time step for surface tension
  double dt3=dt1;
  float surfmax=0;
  if(SurfCoef){
	for(unsigned isurf=0; isurf<MkListSize; isurf++)surfmax=((PhaseData[isurf].PhaseSurf>surfmax)? PhaseData[isurf].PhaseSurf : surfmax);
	dt3=0.25*sqrt(RhopMax*H*H*H/(2.f*PI*surfmax));
  }
  //-dt new value of time step.
  double dt_temp=min(dt2,dt3);
  double dt=double(CFLnumber)*min(dt1,dt_temp);
//�����������������������������������������������������������������������//MP
  if(DtFixed)dt=DtFixed->GetDt(float(TimeStep),float(dt));
  if(dt<double(DtMin)){ dt=double(DtMin); DtModif++; }
  if(SaveDt && final)SaveDt->AddValues(TimeStep,dt,dt1*CFLnumber,dt2*CFLnumber,AceMax,ViscDtMax,VelMax);
  return(dt);
}

//==============================================================================
/// Calcula Shifting final para posicion de particulas.
/// Computes final shifting distance for the particle position. (only for single-phase flows)
//==============================================================================
void JSphGpu::RunShifting(double dt){
  TmgStart(Timers,TMG_SuShifting);
  const double coeftfs=(Simulate2D? 2.0: 3.0)-ShiftTFS;
  cusph::RunShifting(Np,Npb,dt,ShiftCoef,ShiftTFS,coeftfs,Velrhopg,ShiftDetectg,ShiftPosg);
  TmgStop(Timers,TMG_SuShifting);
}

//==============================================================================
/// Procesa movimiento de boundary particles
/// Processes boundary particle movement
//==============================================================================
void JSphGpu::RunMotion(double stepdt){
  const char met[]="RunMotion";
  TmgStart(Timers,TMG_SuMotion);

  unsigned nmove=0;
  if(Motion->ProcesTime(TimeStep+MotionTimeMod,stepdt)){
    nmove=Motion->GetMovCount();
    if(nmove){
      cusph::CalcRidp(PeriActive!=0,Npb,0,CaseNfixed,CaseNfixed+CaseNmoving,Codeg,Idpg,RidpMoveg);
      //-Movimiento de particulas boundary
      //-Movement of boundary particles
      for(unsigned c=0;c<nmove;c++){
        unsigned ref;
        tdouble3 mvsimple;
        tmatrix4d mvmatrix;
        if(Motion->GetMov(c,ref,mvsimple,mvmatrix)){//-Movimiento simple //-Simple movement
          const unsigned pini=MotionObjBegin[ref]-CaseNfixed,np=MotionObjBegin[ref+1]-MotionObjBegin[ref];
          mvsimple=OrderCode(mvsimple);
          if(Simulate2D)mvsimple.y=0;
          const tfloat3 mvvel=ToTFloat3(mvsimple/TDouble3(stepdt));
          cusph::MoveLinBound(PeriActive,np,pini,mvsimple,mvvel,RidpMoveg,Posxyg,Poszg,Dcellg,Velrhopg,Codeg);
        }
        else{//-Movimiento con matriz //-Movement using a matrix
          const unsigned pini=MotionObjBegin[ref]-CaseNfixed,np=MotionObjBegin[ref+1]-MotionObjBegin[ref];
          mvmatrix=OrderCode(mvmatrix);
          cusph::MoveMatBound(PeriActive,Simulate2D,np,pini,mvmatrix,stepdt,RidpMoveg,Posxyg,Poszg,Dcellg,Velrhopg,Codeg);
        } 
      }
      BoundChanged=true;
    }
  }
  //-Procesa otros modos de motion.
  //-Processes other motion modes.
  if(WaveGen){
    if(!nmove)cusph::CalcRidp(PeriActive!=0,Npb,0,CaseNfixed,CaseNfixed+CaseNmoving,Codeg,Idpg,RidpMoveg);
    BoundChanged=true;
    //-Gestion de WaveGen.
    //-Management of WaveGen.
    if(WaveGen)for(unsigned c=0;c<WaveGen->GetCount();c++){
      tdouble3 mvsimple;
      tmatrix4d mvmatrix;
      unsigned nparts;
      unsigned idbegin;
      if(WaveGen->GetMotion(c,TimeStep+MotionTimeMod,stepdt,mvsimple,mvmatrix,nparts,idbegin)){//-Movimiento simple ///Simple movement
        mvsimple=OrderCode(mvsimple);
        if(Simulate2D)mvsimple.y=0;
        const tfloat3 mvvel=ToTFloat3(mvsimple/TDouble3(stepdt));
        cusph::MoveLinBound(PeriActive,nparts,idbegin-CaseNfixed,mvsimple,mvvel,RidpMoveg,Posxyg,Poszg,Dcellg,Velrhopg,Codeg);
      }
      else{
        mvmatrix=OrderCode(mvmatrix);
        cusph::MoveMatBound(PeriActive,Simulate2D,nparts,idbegin-CaseNfixed,mvmatrix,stepdt,RidpMoveg,Posxyg,Poszg,Dcellg,Velrhopg,Codeg);
      }
    }
  }
  TmgStop(Timers,TMG_SuMotion);
}

//==============================================================================
/// Muestra los temporizadores activos.
/// Displays the active timers.
//==============================================================================
void JSphGpu::ShowTimers(bool onlyfile){
  JLog2::TpMode_Out mode=(onlyfile? JLog2::Out_File: JLog2::Out_ScrFile);
  Log->Print("\n[GPU Timers]",mode);
  if(!SvTimers)Log->Print("none",mode);
  else for(unsigned c=0;c<TimerGetCount();c++)if(TimerIsActive(c))Log->Print(TimerToText(c),mode);
}

//==============================================================================
/// Devuelve string con nombres y valores de los timers activos.
/// Returns string with numbers and values of the active timers. 
//==============================================================================
void JSphGpu::GetTimersInfo(std::string &hinfo,std::string &dinfo)const{
  for(unsigned c=0;c<TimerGetCount();c++)if(TimerIsActive(c)){
    hinfo=hinfo+";"+TimerGetName(c);
    dinfo=dinfo+";"+fun::FloatStr(TimerGetValue(c)/1000.f);
  }
}

