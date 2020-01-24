/*
+++ libhpnn - High Performance Neural Network library - file: cuda_snn.cu +++
    Copyright (C) 2019  Okadome Valencia Hubert

    This file is part of libhpnn.

    libhpnn is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    libhpnn is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Foobar.  If not, see <https://www.gnu.org/licenses/>.
*/
#include <stdio.h>
#include <cuda_runtime.h>
#ifdef _CUBLAS
#include <cublas_v2.h>
#endif
#include <libhpnn/common.h>
#include <libhpnn/ann.h>
/*CUDA specific*/
#include <libhpnn/cuda_ann.h>
#include <libhpnn/cuda_snn.h>

/*^^^ useful to launch kernels*/
#define _WP  32
#define _TPW 32
#define _TPB (_TPW*_WP)
#define _KG(n) ((n+_TPB-1)/(_TPB)),_TPB
/*---------------*/
/*+++ KERNELS +++*/
/*---------------*/
__global__
void fw_smax(int n, double dv, double *out){
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;
	for (int i = index; i < n; i += stride)
		out[i] = exp( out[i] - 1.0 ) / dv;
}
__global__
void fw_scal(int n, double dv, double *out){
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;
	for (int i = index; i < n; i += stride)
		out[i] = out[i] / dv;
}
__global__
void amb_smax(int n, double *res, double *train, double *out){
        int index = blockIdx.x * blockDim.x + threadIdx.x;
        int stride = blockDim.x * gridDim.x;
        for (int i = index; i < n; i += stride)
		res[i] = train[i] * log( out[i] + TINY );
}
__global__
void fw_s_acc(int m,int n, double *mat,double *vec,double *res){
        int tid=threadIdx.x+blockIdx.x*blockDim.x;
        double sum=0.;
        if(tid<n){
                /*a full line*/
                for(int i=0; i<m; i++) sum += vec[i]*mat[(tid*m)+i];
                res[tid]=sum;
        }
}
__global__
void amb_smax_acc(int n, double *res, double *train, double *out){
	extern __shared__ double sh_data[];
	int tid=threadIdx.x;
	int i=blockIdx.x*(blockDim.x*2)+threadIdx.x;
	double mySum = (i < n) ? train[i]*log(out[i]+TINY) : 0;
	if(i+blockDim.x < n) mySum += train[i+blockDim.x]*log(out[i+blockDim.x]+TINY);
	sh_data[tid]=mySum;
	__syncthreads();
	/*reduction in shared memory*/
	for(int s=blockDim.x/2;s>0;s>>=1){
		if(tid<s) sh_data[tid] += sh_data[tid+s];
		__syncthreads();
	}
	/*result*/
	if(tid==0) out[blockIdx.x]=sh_data[0];
}
__global__
void dv_acc(int n,double *res,double *out){
	extern __shared__ double sh_data[];
	int tid=threadIdx.x;
	int i=blockIdx.x*(blockDim.x*2)+threadIdx.x;
	double mySum = (i < n) ? exp(out[i]-1.0) : 0;
	if(i+blockDim.x < n) mySum += exp(out[i+blockDim.x]-1.0);
	sh_data[tid]=mySum;
	__syncthreads();
	/*reduction in shared memory*/
	for(int s=blockDim.x/2;s>0;s>>=1){
		if(tid<s) sh_data[tid] += sh_data[tid+s];
		__syncthreads();
	}
	/*result*/
	if(tid==0) res[blockIdx.x]=sh_data[0];
}
__global__
void dsmax_diff(int n, double *t, double *o, double *y){
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	int stride = blockDim.x * gridDim.x;
	for (int i = index; i < n; i += stride)
		y[i] = ( t[i] - o[i] );
}
/*calculate exp(x-1) _and_ accumulate dv*/
__global__
void softmax_acc(int n,double *res,double *out){
	extern __shared__ double sh_data[];
	int tid=threadIdx.x;
	int i=blockIdx.x*(blockDim.x*2)+threadIdx.x;
	double mySum;
	if(i<n){
		out[i] = exp(out[i]-1.0);
		mySum = out[i];
	}else{
		mySum = 0.;
	}
	if(i+blockDim.x < n) {
		out[i+blockDim.x] = exp(out[i+blockDim.x]-1.0);
		mySum += out[i+blockDim.x];
	}
	sh_data[tid]=mySum;
	__syncthreads();
	/*reduction in shared memory*/
	for(int s=blockDim.x/2;s>0;s>>=1){
		if(tid<s) sh_data[tid] += sh_data[tid+s];
		__syncthreads();
	}
	/*result*/
	if(tid==0) res[blockIdx.x]=sh_data[0];
}




/*-----------------*/
/* The C interface */
/*-----------------*/
extern "C"{
#define _K (*kernel)
/*-----------------------------*/
/*+++ forward kernel update +++*/
/*-----------------------------*/
void scuda_snn_forward(_kernel *kernel,cudastreams *cudas){
	int idx,jdx;
	int M,N,red;
	int rem;
#ifdef _CUBLAS
        double _alpha=1.0;
        double _beta =0.0;
#endif
	double dv;
/*+++ I - input +++*/
	N=_K.hiddens[0].n_neurons;
	M=_K.hiddens[0].n_inputs;
	red=N/cudas->cuda_n_streams;
	rem=N%cudas->cuda_n_streams;
#ifdef   _CUBLAS
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
		cublasDgemv(cudas->cuda_handle,
			CUBLAS_OP_T,M,red,&_alpha,_K.hiddens[0].cuda_w+jdx*M*red,M,
			_K.cuda_in,1,&_beta,_K.hiddens[0].cuda_v+jdx*red,1);
		CHK_ERR(fw_gemv);
		sigmoid<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
			(red,_K.hiddens[0].cuda_v+jdx*red);
		CHK_ERR(fw_sigmoid);
	}
	cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
	cublasDgemv(cudas->cuda_handle,
		CUBLAS_OP_T,M,red+rem,&_alpha,_K.hiddens[0].cuda_w+jdx*M*red,M,
		_K.cuda_in,1,&_beta,_K.hiddens[0].cuda_v+jdx*red,1);
	CHK_ERR(fw_gemv);
	sigmoid<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
		(red+rem,_K.hiddens[0].cuda_v+jdx*red);
	CHK_ERR(fw_sigmoid);
#else  /*_CUBLAS*/
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		fw_mv_acc<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
			(M,red,_K.hiddens[0].cuda_w+jdx*M*red,_K.cuda_in,
				_K.hiddens[0].cuda_v+jdx*red);
		CHK_ERR(fw_mv_acc);
	}
	fw_mv_acc<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
		(M,red+rem,_K.hiddens[0].cuda_w+jdx*M*red,_K.cuda_in,
			_K.hiddens[0].cuda_v+jdx*red);
	CHK_ERR(fw_mv_acc);
#endif /*_CUBLAS*/
	cudaDeviceSynchronize();/*get all stream at this point*/
/*+++ II - hidden(s) +++*/
	for(idx=1;idx<_K.n_hiddens;idx++){
		N=_K.hiddens[idx].n_neurons;
		M=_K.hiddens[idx].n_inputs;
		red=N/cudas->cuda_n_streams;
		rem=N%cudas->cuda_n_streams;
#ifdef   _CUBLAS
		for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
			cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
			cublasDgemv(cudas->cuda_handle,
				CUBLAS_OP_T,M,red,&_alpha,_K.hiddens[idx].cuda_w+jdx*M*red,M,
				_K.hiddens[idx-1].cuda_v,1,&_beta,
				_K.hiddens[idx].cuda_v+jdx*red,1);
			CHK_ERR(fw_gemv);
			sigmoid<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
				(red,_K.hiddens[idx].cuda_v+jdx*red);
			CHK_ERR(fw_sigmoid);
		}
		/*launch the last kernel*/
		cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
		cublasDgemv(cudas->cuda_handle,
			CUBLAS_OP_T,M,red+rem,&_alpha,_K.hiddens[idx].cuda_w+jdx*M*red,M,
			_K.hiddens[idx-1].cuda_v,1,&_beta,
			_K.hiddens[idx].cuda_v+jdx*red,1);
		CHK_ERR(cublas_1);
		sigmoid<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
			(red+rem,_K.hiddens[idx].cuda_v+jdx*red);
		CHK_ERR(kernel_1);
#else  /*_CUBLAS*/
		for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
			fw_mv_acc<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
				(M,red,_K.hiddens[idx].cuda_w+jdx*M*red,
				_K.hiddens[idx-1].cuda_v,_K.hiddens[idx].cuda_v+jdx*red);
			CHK_ERR(fw_mv_acc);
		}
		fw_mv_acc<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
			(M,red+rem,_K.hiddens[idx].cuda_w+jdx*M*red,
			_K.hiddens[idx-1].cuda_v,_K.hiddens[idx].cuda_v+jdx*red);
		CHK_ERR(fw_mv_acc);
#endif /*_CUBLAS*/
		cudaDeviceSynchronize();
	}
/*+++ III - output +++*/
	N=_K.output.n_neurons;
	M=_K.output.n_inputs;
	red=N/cudas->cuda_n_streams;
	rem=N%cudas->cuda_n_streams;
	dv=TINY;
#ifdef   _CUBLAS
	DOUBLE tmp_dv[cudas->cuda_n_streams];
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
		cublasDgemv(cudas->cuda_handle,
			CUBLAS_OP_T,M,red,&_alpha,_K.output.cuda_w+jdx*M*red,M,
			_K.hiddens[_K.n_hiddens-1].cuda_v,1,
			&_beta,_K.output.cuda_v+jdx*red,1);
		CHK_ERR(fw_gemv);
		softmax_acc<<<_KG(red),sizeof(double)*2*(_TPB),cudas->cuda_streams[jdx]>>>
			(red,_K.tmp_gpu+jdx*red,_K.output.cuda_v+jdx*red);
		CHK_ERR(fw_softmax_acc);
	}
	cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
	cublasDgemv(cudas->cuda_handle,
		CUBLAS_OP_T,M,red+rem,&_alpha,_K.output.cuda_w+jdx*M*red,M,
		_K.hiddens[_K.n_hiddens-1].cuda_v,1,&_beta,_K.output.cuda_v+jdx*red,1);
	CHK_ERR(fw_gemv);
	softmax_acc<<<_KG(red+rem),sizeof(double)*2*(_TPB),cudas->cuda_streams[jdx]>>>
		(red+rem,_K.tmp_gpu+jdx*red,_K.output.cuda_v+jdx*red);
	/*SOFTMAX: calculate dv*/
	cudaDeviceSynchronize();
	CUDA_G2C_CP(&dv,&(_K.tmp_gpu[0]),1,double);
	dv=1.0/dv;
	/*SOFTMAX: calculate output*/
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
		cublasDscal(cudas->cuda_handle,red,&dv,_K.output.cuda_v+jdx*red,1);
		CHK_ERR(fw_scal);
	}
	cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
	cublasDscal(cudas->cuda_handle,red+rem,&dv,_K.output.cuda_v+jdx*red,1);
	CHK_ERR(fw_scal);
#else  /*_CUBLAS*/
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		fw_s_acc<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
			(M,red,_K.output.cuda_w+jdx*M*red,_K.hiddens[_K.n_hiddens-1].cuda_v,
			_K.output.cuda_v+jdx*red);
		CHK_ERR(fw_s_acc);
		softmax_acc<<<_KG(red),sizeof(double)*2*(_TPB),cudas->cuda_streams[jdx]>>>
			(red,_K.tmp_gpu,_K.output.cuda_v+jdx*red);
		CHK_ERR(fw_softmax_acc);
	}
	fw_s_acc<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
		(M,red+rem,_K.output.cuda_w+jdx*M*red,_K.hiddens[_K.n_hiddens-1].cuda_v,
		_K.output.cuda_v+jdx*red);
	CHK_ERR(fw_s_acc);
	softmax_acc<<<_KG(red+rem),sizeof(double)*2*(_TPB),cudas->cuda_streams[jdx]>>>
		(red+rem,_K.tmp_gpu,_K.output.cuda_v+jdx*red);
	CHK_ERR(fw_softmax_acc);
	/*SOFTMAX: calculate dv*/
	cudaDeviceSynchronize();
	CUDA_G2C_CP(&dv,&(_K.tmp_gpu[0]),1,double);
	/*SOFTMAX: calculate output*/
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		fw_scal<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
			(red,dv,_K.output.cuda_v+jdx*red);
		CHK_ERR(fw_scal);
	}
	fw_scal<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
		(red+rem,dv,_K.output.cuda_v+jdx*red);
	CHK_ERR(fw_scal);
#endif /*_CUBLAS*/
	cudaDeviceSynchronize();
}
/*--------------------------------*/
/*+++ Calculate Training Error +++*/
/*--------------------------------*/
double scuda_snn_error(_kernel *kernel,double *train,cudastreams *cudas){
/*TODO: why no streams here?*/
	double dEp=0.;
#ifdef   _CUBLAS
	amb_smax<<<_KG(_K.n_outputs)>>>(_K.n_outputs,_K.tmp_gpu,train,_K.output.cuda_v);
	CHK_ERR(err_amb_smax);
	cublasSetStream(cudas->cuda_handle,NULL);
	cublasDasum(cudas->cuda_handle,_K.n_outputs,_K.tmp_gpu,1,&dEp);
	CHK_ERR(err_asum);
#else  /*_CUBLAS*/
	/*no streams?*/
	amb_smax_acc<<<_KG(_K.n_outputs),sizeof(double)*2*(_TPB)>>>
		(_K.n_outputs,_K.tmp_gpu,train,_K.output.cuda_v);
	CHK_ERR(err_amb_smax_acc);
	CUDA_G2C_CP(&dEp,&(_K.tmp_gpu[0]),1,double);
	CHK_ERR(err_g2c_cp);
#endif /*_CUBLAS*/
	dEp/=-1.0*_K.n_outputs;
	return dEp;
}
/*------------------------*/
/*+++ Calculate deltas +++*/
/*------------------------*/
void scuda_snn_delta(_kernel *kernel,double *train,double **delta_ptr,cudastreams *cudas){
	int idx,jdx;
	int M,N,red;
	int rem;
#ifdef _CUBLAS
	double _alpha=1.0;
	double _beta =0.0;
#endif /*_CUBLAS*/
/*^^^ output*/
	N=_K.n_outputs;
	red=N/cudas->cuda_n_streams;
	rem=N%cudas->cuda_n_streams;
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		dsmax_diff<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
			(red,train+jdx*red,_K.output.cuda_v+jdx*red,
			delta_ptr[_K.n_hiddens]+jdx*red);
		CHK_ERR(train_dsmax_dif);
	}
	dsmax_diff<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
		(red+rem,train+jdx*red,_K.output.cuda_v+jdx*red,
		delta_ptr[_K.n_hiddens]+jdx*red);
	CHK_ERR(train_dsmax_dif);
	cudaDeviceSynchronize();
/*^^^ output to hidden*/
	/*distribution over M due to transposed operations*/
	N=_K.output.n_neurons;
	M=_K.output.n_inputs;
	red=M/cudas->cuda_n_streams;
	rem=M%cudas->cuda_n_streams;
#ifdef   _CUBLAS
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
		cublasDgemv(cudas->cuda_handle,CUBLAS_OP_N,red,N,
		&_alpha,_K.output.cuda_w+jdx*red,M,delta_ptr[_K.n_hiddens],1,
		&_beta,delta_ptr[_K.n_hiddens-1]+jdx*red,1);
		CHK_ERR(train_gemv);
		dsigmoid<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
			(red,_K.hiddens[_K.n_hiddens-1].cuda_v+jdx*red,
			delta_ptr[_K.n_hiddens-1]+jdx*red);
		CHK_ERR(train_dsigmoid);
	}
	cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
	cublasDgemv(cudas->cuda_handle,CUBLAS_OP_N,red+rem,N,
	&_alpha,_K.output.cuda_w+jdx*red,M,delta_ptr[_K.n_hiddens],1,
	&_beta,delta_ptr[_K.n_hiddens-1]+jdx*red,1);
	CHK_ERR(train_gemv);
	dsigmoid<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
		(red+rem,_K.hiddens[_K.n_hiddens-1].cuda_v+jdx*red,
		delta_ptr[_K.n_hiddens-1]+jdx*red);
	CHK_ERR(train_dsigmoid);
#else  /*_CUBLAS*/
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		dsigmoid_mul_delta_T<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
		(red,M,N,_K.output.cuda_w+jdx*red,delta_ptr[_K.n_hiddens],
		_K.hiddens[_K.n_hiddens-1].cuda_v+jdx*red,
		delta_ptr[_K.n_hiddens-1]+jdx*red);
		CHK_ERR(train_dsigmoid_mul_delta_T);
	}
	dsigmoid_mul_delta_T<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
		(red+rem,M,N,_K.output.cuda_w+jdx*red,delta_ptr[_K.n_hiddens],
		_K.hiddens[_K.n_hiddens-1].cuda_v+jdx*red,
		delta_ptr[_K.n_hiddens-1]+jdx*red);
	CHK_ERR(train_dsigmoid_mul_delta_T);
#endif /*_CUBLAS*/
	cudaDeviceSynchronize();
/*^^^ hidden to hidden (if any)*/
	if(_K.n_hiddens>1){
		for(idx=(_K.n_hiddens-2);idx>0;idx--){
			N=_K.hiddens[idx+1].n_neurons;
			M=_K.hiddens[idx+1].n_inputs;
			red=M/cudas->cuda_n_streams;
			rem=M%cudas->cuda_n_streams;
#ifdef   _CUBLAS
			for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
				cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
				cublasDgemv(cudas->cuda_handle,CUBLAS_OP_N,red,N,
				&_alpha,_K.hiddens[idx+1].cuda_w+jdx*red,M,delta_ptr[idx+1],1,
				&_beta,delta_ptr[idx]+jdx*red,1);
				CHK_ERR(train_gemv);
				dsigmoid<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
					(red,_K.hiddens[idx].cuda_v+jdx*red,delta_ptr[idx]+jdx*red);
				CHK_ERR(train_dsigmoid);
			}
			cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
			cublasDgemv(cudas->cuda_handle,CUBLAS_OP_N,red+rem,N,
			&_alpha,_K.hiddens[idx+1].cuda_w+jdx*red,M,delta_ptr[idx+1],1,
			&_beta,delta_ptr[idx]+jdx*red,1);
			CHK_ERR(train_gemv);
			dsigmoid<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
				(red+rem,_K.hiddens[idx].cuda_v+jdx*red,delta_ptr[idx]+jdx*red);
			CHK_ERR(train_dsigmoid);
#else  /*_CUBLAS*/
			for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
				dsigmoid_mul_delta_T<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
					(red,M,N,_K.hiddens[idx+1].cuda_w+jdx*red,delta_ptr[idx+1],
					_K.hiddens[idx].cuda_v+jdx*red,delta_ptr[idx]+jdx*red);
				CHK_ERR(train_dsigmoid_mul_delta_T);
			}
			dsigmoid_mul_delta_T<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
				(red+rem,M,N,_K.hiddens[idx+1].cuda_w+jdx*red,delta_ptr[idx+1],
				_K.hiddens[idx].cuda_v+jdx*red,delta_ptr[idx]+jdx*red);
			CHK_ERR(train_dsigmoid_mul_delta_T);
#endif /*_CUBLAS*/
			cudaDeviceSynchronize();
		}
		/*add zero*/
		N=_K.hiddens[1].n_neurons;
		M=_K.hiddens[1].n_inputs;
		red=M/cudas->cuda_n_streams;
		rem=M%cudas->cuda_n_streams;
#ifdef   _CUBLAS
		for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
			cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
			cublasDgemv(cudas->cuda_handle,CUBLAS_OP_N,red,N,
			&_alpha,_K.hiddens[1].cuda_w+jdx*red,M,delta_ptr[1],1,
			&_beta,delta_ptr[0]+jdx*red,1);
			CHK_ERR(train_gemv);
			dsigmoid<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
				(red,_K.hiddens[0].cuda_v+jdx*red,delta_ptr[0]+jdx*red);
			CHK_ERR(train_dsigmoid);
		}
		cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
		cublasDgemv(cudas->cuda_handle,CUBLAS_OP_N,red+rem,N,
		&_alpha,_K.hiddens[1].cuda_w+jdx*red,M,delta_ptr[1],1,
		&_beta,delta_ptr[0]+jdx*red,1);
		CHK_ERR(train_gemv);
		dsigmoid<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
			(red+rem,_K.hiddens[0].cuda_v+jdx*red,delta_ptr[0]+jdx*red);
		CHK_ERR(train_dsigmoid);
#else  /*_CUBLAS*/
		for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
			dsigmoid_mul_delta_T<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
				(red,M,N,_K.hiddens[1].cuda_w+jdx*red,
			delta_ptr[1],_K.hiddens[0].cuda_v+jdx*red,delta_ptr[0]+jdx*red);
			CHK_ERR(train_dsigmoid_mul_delta_T);
		}
		dsigmoid_mul_delta_T<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
			(red+rem,M,N,_K.hiddens[1].cuda_w+jdx*red,
		delta_ptr[1],_K.hiddens[0].cuda_v+jdx*red,delta_ptr[0]+jdx*red);
		CHK_ERR(train_dsigmoid_mul_delta_T);
#endif /*_CUBLAS*/
		cudaDeviceSynchronize();
	}
}
#define LEARN_RATE 0.01
/*------------------------*/
/*+++ back-propagation +++*/
/*------------------------*/
double scuda_snn_train(_kernel *kernel,double *train,cudastreams *cudas){
	int idx,jdx;
	int M,N,red;
	int rem;
	double **delta_ptr;
	double Ep =0.;
	double Epr=0.;
#ifdef _CUBLAS
	double _alpha=1.0;
#endif /*_CUBLAS*/
	/*allocate delta_ptr*/
	ALLOC(delta_ptr,_K.n_hiddens+1,DOUBLE *);/*HOST*/
	for(idx=0;idx<_K.n_hiddens;idx++)
		CUDA_ALLOC(delta_ptr[idx],_K.hiddens[idx].n_neurons,DOUBLE);/*DEVICE*/
	CUDA_ALLOC(delta_ptr[_K.n_hiddens],_K.n_outputs,DOUBLE);/*DEVICE*/
/*+++ I - FORWARD +++*/
/*>>> in all cases, the FORWARD move should have already be done <<<*/
	Ep=scuda_snn_error(kernel,train,cudas);
//	printf("TRAINING INITIAL ERROR: %.15f\n",Ep);
/*+++ II - DELTAS +++*/
	scuda_snn_delta(kernel,train,delta_ptr,cudas);
/*+++ III - back propagation +++*/
/*^^^ output*/
	N=_K.output.n_neurons;
	M=_K.output.n_inputs;
	red=N/cudas->cuda_n_streams;
	rem=N%cudas->cuda_n_streams;
#ifdef   _CUBLAS
	_alpha=LEARN_RATE;
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
		cublasDger(cudas->cuda_handle,M,red,&_alpha,
			_K.hiddens[_K.n_hiddens-1].cuda_v,1,delta_ptr[_K.n_hiddens]+jdx*red,
			1,_K.output.cuda_w+jdx*M*red,M);
		CHK_ERR(train_ger);
	}
	cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
	cublasDger(cudas->cuda_handle,M,red+rem,&_alpha,
		_K.hiddens[_K.n_hiddens-1].cuda_v,1,delta_ptr[_K.n_hiddens]+jdx*red,
		1,_K.output.cuda_w+jdx*M*red,M);
	CHK_ERR(train_ger);
#else  /*_CUBLAS*/
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		ger_acc<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
			(M,red,LEARN_RATE,delta_ptr[_K.n_hiddens]+jdx*red,
			_K.hiddens[_K.n_hiddens-1].cuda_v,_K.output.cuda_w+jdx*M*red);
		CHK_ERR(train_ger_acc);
	}
	ger_acc<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
		(M,red+rem,LEARN_RATE,delta_ptr[_K.n_hiddens]+jdx*red,
		_K.hiddens[_K.n_hiddens-1].cuda_v,_K.output.cuda_w+jdx*M*red);
	CHK_ERR(train_ger_acc);
#endif /*_CUBLAS*/
	cudaDeviceSynchronize();
/*^^^ hiddens*/
	for(idx=(_K.n_hiddens-1);idx>0;idx--){
		N=_K.hiddens[idx].n_neurons;
		M=_K.hiddens[idx].n_inputs;
		red=N/cudas->cuda_n_streams;
		rem=N%cudas->cuda_n_streams;
#ifdef   _CUBLAS
		for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
			cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
			cublasDger(cudas->cuda_handle,M,red,&_alpha,
			_K.hiddens[idx-1].cuda_v,1,delta_ptr[idx]+jdx*red,1,
			_K.hiddens[idx].cuda_w+jdx*M*red,M);
			CHK_ERR(train_ger);
		}
		cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
		cublasDger(cudas->cuda_handle,M,red+rem,&_alpha,
		_K.hiddens[idx-1].cuda_v,1,delta_ptr[idx]+jdx*red,1,
		_K.hiddens[idx].cuda_w+jdx*M*red,M);
		CHK_ERR(train_ger);
#else  /*_CUBLAS*/
		for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
			ger_acc<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
				(M,red,LEARN_RATE,delta_ptr[idx]+jdx*red,
				_K.hiddens[idx-1].cuda_v,_K.hiddens[idx].cuda_w+jdx*M*red);
			CHK_ERR(train_ger_acc);
		}
		ger_acc<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
			(M,red+rem,LEARN_RATE,delta_ptr[idx]+jdx*red,
			_K.hiddens[idx-1].cuda_v,_K.hiddens[idx].cuda_w+jdx*M*red);
		CHK_ERR(train_ger_acc);
#endif /*_CUBLAS*/
		cudaDeviceSynchronize();
	}
	/*add zero*/
	N=_K.hiddens[0].n_neurons;
	M=_K.hiddens[0].n_inputs;
	red=N/cudas->cuda_n_streams;
	rem=N%cudas->cuda_n_streams;
#ifdef   _CUBLAS
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
		cublasDger(cudas->cuda_handle,M,red,&_alpha,_K.cuda_in,1,
			delta_ptr[0]+jdx*red,1,_K.hiddens[0].cuda_w+jdx*M*red,M);
		CHK_ERR(train_ger);
	}
	cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
	cublasDger(cudas->cuda_handle,M,red+rem,&_alpha,_K.cuda_in,1,
		delta_ptr[0]+jdx*red,1,_K.hiddens[0].cuda_w+jdx*M*red,M);
	CHK_ERR(train_ger);
#else  /*_CUBLAS*/
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		ger_acc<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
			(M,red,LEARN_RATE,delta_ptr[0]+jdx*red,_K.cuda_in,
			_K.hiddens[0].cuda_w+jdx*M*red);
		CHK_ERR(train_ger_acc);
	}
	ger_acc<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
		(M,red+rem,LEARN_RATE,delta_ptr[0]+jdx*red,_K.cuda_in,
		_K.hiddens[0].cuda_w+jdx*M*red);
	CHK_ERR(train_ger_acc);
#endif /*_CUBLAS*/
	cudaDeviceSynchronize();
/*+++ IV - update error +++*/
	/*update kernel*/
	scuda_snn_forward(kernel,cudas);
	Epr=scuda_snn_error(kernel,train,cudas);
//	fprintf(stdout,"TRAINING UPDATED ERROR: %.15f\n",Epr);
/*+++ V - cleanup +++*/
	for(idx=0;idx<(_K.n_hiddens+1);idx++){
		CUDA_FREE(delta_ptr[idx]);
		delta_ptr[idx]=NULL;
	}
	FREE(delta_ptr);
	CHK_ERR(free_1);
	return Ep-Epr;
}
/*--------------------------------------*/
/*+++ back-propagation with momentum +++*/
/*--------------------------------------*/
double scuda_snn_train_momentum(_kernel *kernel,double *train,double moment,cudastreams *cudas){
	int idx,jdx;
	int M,N,red;
	int rem;
	double **delta_ptr;
	double Ep =0.;
	double Epr=0.;
	/**/
#ifdef _CUBLAS
	double _alpha=1.0;
	double _un=1.0;
	int kdx;
#endif /*_CUBLAS*/
	/*allocate delta_ptr*/
	ALLOC(delta_ptr,_K.n_hiddens+1,DOUBLE *);/*HOST*/
	for(idx=0;idx<_K.n_hiddens;idx++)
		CUDA_ALLOC(delta_ptr[idx],_K.hiddens[idx].n_neurons,DOUBLE);/*DEVICE*/
	CUDA_ALLOC(delta_ptr[_K.n_hiddens],_K.n_outputs,DOUBLE);/*DEVICE*/
/*+++ I - FORWARD +++*/
/*>>> in all cases, the FORWARD move should have already be done <<<*/
	Ep=scuda_snn_error(kernel,train,cudas);
///	printf("TRAINING INITIAL ERROR: %.15f\n",Ep);
/*+++ II - DELTAS +++*/
	scuda_snn_delta(kernel,train,delta_ptr,cudas);
/*+++ III - back propagation +++*/
/*^^^ output*/
	N=_K.output.n_neurons;
	M=_K.output.n_inputs;
	red=N/cudas->cuda_n_streams;
	rem=N%cudas->cuda_n_streams;
#ifdef   _CUBLAS
	_alpha=LEARN_RATE;
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
		cublasDger(cudas->cuda_handle,M,red,&_alpha,
			_K.hiddens[_K.n_hiddens-1].cuda_v,1,delta_ptr[_K.n_hiddens]+jdx*red,
			1,_K.cuda_dw[_K.n_hiddens]+jdx*M*red,M);
		CHK_ERR(moment_ger);
		cublasDaxpy(cudas->cuda_handle,red*M,&_un,
			_K.cuda_dw[_K.n_hiddens]+jdx*M*red,1,_K.output.cuda_w+jdx*M*red,1);
		CHK_ERR(moment_axpy);
		cublasDscal(cudas->cuda_handle,red*M,&moment,
			_K.cuda_dw[_K.n_hiddens]+jdx*M*red,1);
		CHK_ERR(moment_scal);
	}
	cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
	cublasDger(cudas->cuda_handle,M,red+rem,&_alpha,
		_K.hiddens[_K.n_hiddens-1].cuda_v,1,delta_ptr[_K.n_hiddens]+jdx*red,
		1,_K.cuda_dw[_K.n_hiddens]+jdx*M*red,M);
	CHK_ERR(moment_ger);
	cublasDaxpy(cudas->cuda_handle,(red+rem)*M,&_un,
		_K.cuda_dw[_K.n_hiddens]+jdx*M*red,1,_K.output.cuda_w+jdx*M*red,1);
	CHK_ERR(moment_axpy);
	cublasDscal(cudas->cuda_handle,(red+rem)*M,&moment,
		_K.cuda_dw[_K.n_hiddens]+jdx*M*red,1);
	CHK_ERR(moment_scal);
#else  /*_CUBLAS*/
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		ger_dw_acc<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
			(M,red,LEARN_RATE,moment,delta_ptr[_K.n_hiddens]+jdx*red,
			_K.hiddens[_K.n_hiddens-1].cuda_v,
			_K.cuda_dw[_K.n_hiddens]+jdx*M*red,_K.output.cuda_w+jdx*M*red);
		CHK_ERR(moment_ger_dw_acc);
	}
	ger_dw_acc<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
		(M,red+rem,LEARN_RATE,moment,delta_ptr[_K.n_hiddens]+jdx*red,
		_K.hiddens[_K.n_hiddens-1].cuda_v,
		_K.cuda_dw[_K.n_hiddens]+jdx*M*red,_K.output.cuda_w+jdx*M*red);
	CHK_ERR(moment_ger_dw_acc);
#endif /*_CUBLAS*/
	cudaDeviceSynchronize();
/*^^^ hiddens*/
	for(idx=(_K.n_hiddens-1);idx>0;idx--){
		N=_K.hiddens[idx].n_neurons;
		M=_K.hiddens[idx].n_inputs;
		red=N/cudas->cuda_n_streams;
		rem=N%cudas->cuda_n_streams;
#ifdef   _CUBLAS
		for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
			cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
			cublasDger(cudas->cuda_handle,M,red,&_alpha,
				_K.hiddens[idx-1].cuda_v,1,delta_ptr[idx]+jdx*red,1,
				_K.cuda_dw[idx]+jdx*M*red,M);
			CHK_ERR(moment_ger);
			cublasDaxpy(cudas->cuda_handle,red*M,&_un,
				_K.cuda_dw[idx]+jdx*M*red,1,_K.hiddens[idx].cuda_w+jdx*M*red,1);
			CHK_ERR(moment_axpy);
			cublasDscal(cudas->cuda_handle,red*M,&moment,
				_K.cuda_dw[idx]+jdx*M*red,1);
			CHK_ERR(moment_scal);
		}
		cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
		cublasDger(cudas->cuda_handle,M,red+rem,&_alpha,
			_K.hiddens[idx-1].cuda_v,1,delta_ptr[idx]+jdx*red,1,
			_K.cuda_dw[idx]+jdx*M*red,M);
		CHK_ERR(moment_ger);
		cublasDaxpy(cudas->cuda_handle,(red+rem)*M,&_un,
			_K.cuda_dw[idx]+jdx*M*red,1,_K.hiddens[idx].cuda_w+jdx*M*red,1);
		CHK_ERR(moment_axpy);
		cublasDscal(cudas->cuda_handle,(red+rem)*M,&moment,
			_K.cuda_dw[idx]+jdx*M*red,1);
		CHK_ERR(moment_scal);
#else  /*_CUBLAS*/
		for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
			ger_dw_acc<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
				(M,red,LEARN_RATE,moment,delta_ptr[idx]+jdx*red,
				_K.hiddens[idx-1].cuda_v,
				_K.cuda_dw[idx]+jdx*M*red,_K.hiddens[idx].cuda_w+jdx*M*red);
			CHK_ERR(moment_ger_dw_acc);
		}
		ger_dw_acc<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
			(M,red+rem,LEARN_RATE,moment,delta_ptr[idx]+jdx*red,
			_K.hiddens[idx-1].cuda_v,
			_K.cuda_dw[idx]+jdx*M*red,_K.hiddens[idx].cuda_w+jdx*M*red);
		CHK_ERR(moment_ger_dw_acc);
#endif /*_CUBLAS*/
		cudaDeviceSynchronize();
	}
	/*add zero*/
	N=_K.hiddens[0].n_neurons;
	M=_K.hiddens[0].n_inputs;
	red=N/cudas->cuda_n_streams;
	rem=N%cudas->cuda_n_streams;
#ifdef   _CUBLAS
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
		cublasDger(cudas->cuda_handle,M,red,&_alpha,_K.cuda_in,1,
			delta_ptr[0]+jdx*red,1,_K.cuda_dw[0]+jdx*M*red,M);
		CHK_ERR(moment_ger);
		cublasDaxpy(cudas->cuda_handle,red*M,&_un,_K.cuda_dw[0]+jdx*M*red,1,
			_K.hiddens[0].cuda_w+jdx*M*red,1);
		CHK_ERR(moment_axpy);
		cublasDscal(cudas->cuda_handle,red*M,&moment,
			_K.cuda_dw[0]+jdx*M*red,1);
		CHK_ERR(moment_scal);
	}
	cublasSetStream(cudas->cuda_handle,cudas->cuda_streams[jdx]);
	cublasDger(cudas->cuda_handle,M,red+rem,&_alpha,_K.cuda_in,1,
		delta_ptr[0]+jdx*red,1,_K.cuda_dw[0]+jdx*M*red,M);
	CHK_ERR(moment_ger);
	cublasDaxpy(cudas->cuda_handle,(red+rem)*M,&_un,_K.cuda_dw[0]+jdx*M*red,1,
		_K.hiddens[0].cuda_w+jdx*M*red,1);
	CHK_ERR(moment_axpy);
	cublasDscal(cudas->cuda_handle,(red+rem)*M,&moment,
		_K.cuda_dw[0]+jdx*M*red,1);
	CHK_ERR(moment_scal);
#else  /*_CUBLAS*/
	for(jdx=0;jdx<cudas->cuda_n_streams-1;jdx++){
		ger_dw_acc<<<_KG(red),0,cudas->cuda_streams[jdx]>>>
			(M,red,LEARN_RATE,moment,delta_ptr[0]+jdx*red,_K.cuda_in,
			_K.cuda_dw[0]+jdx*M*red,_K.hiddens[0].cuda_w+jdx*M*red);
		CHK_ERR(moment_ger_dw_acc);
	}
	ger_dw_acc<<<_KG(red+rem),0,cudas->cuda_streams[jdx]>>>
		(M,red+rem,LEARN_RATE,moment,delta_ptr[0]+jdx*red,_K.cuda_in,
		_K.cuda_dw[0]+jdx*M*red,_K.hiddens[0].cuda_w+jdx*M*red);
	CHK_ERR(moment_ger_dw_acc);
#endif /*_CUBLAS*/
	cudaDeviceSynchronize();
/*+++ IV - update error +++*/
	/*update kernel*/
	scuda_snn_forward(kernel,cudas);
	Epr=scuda_snn_error(kernel,train,cudas);
//	fprintf(stdout,"TRAINING UPDATED ERROR: %.15f\n",Epr);
/*+++ V - cleanup +++*/
	for(idx=0;idx<(_K.n_hiddens+1);idx++){
		CUDA_FREE(delta_ptr[idx]);
		delta_ptr[idx]=NULL;
	}
	FREE(delta_ptr);
	CHK_ERR(free_1);
	return Ep-Epr;
}

}/*extern "C"*/
