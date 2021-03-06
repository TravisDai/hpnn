/*
+++ libhpnn - High Performance Neural Network library - file: cuda_ann.h +++
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
#ifndef CUDA_ANN_H
#define CUDA_ANN_H

__global__ void sigmoid(int n, double *x);
__global__ void _dsigmoid(int n, double *in, double *out);
__global__ void dsigmoid(int n, double *in, double *out);
__global__ void amb(int n, double *out, double *a, double *b);
__global__ void mul_diff(int n, double *t, double *o, double *y);
__global__ void fw_mv_acc(int m,int n, double *mat,double *vec,double *res);
__global__ void amb_acc(int n, double *out, double *a, double *b);
__global__ void dsigmoid_mul_diff(int n, double *t, double *o, double *y);
__global__ void dsigmoid_mul_delta_T(int red,int m,int n, double *w,double *d,
    double *h,double *res);
__global__ void ger_acc(int m,int n,double alpha,double *d,double *h,double *w);
__global__ void ger_dw_acc(int m,int n,double learn,double moment,double *d,
    double *v,double *dw,double *w);

#if __cplusplus
extern "C" {
#endif
void scuda_ann_deallocate(kernel_ann *kernel,cudastreams *cudas);
int64_t scuda_ann_allocate(kernel_ann *kernel,cudastreams *cudas);
BOOL scuda_ann_free_momentum(kernel_ann *kernel,cudastreams *cudas);
int64_t scuda_ann_allocate_momentum(kernel_ann *kernel,cudastreams *cudas);
void scuda_ann_weight_transfer_C2G(kernel_ann *kernel,int index,DOUBLE *weight,
    cudastreams *cudas);
void scuda_ann_weight_transfer_G2C(kernel_ann *kernel,int index,
    DOUBLE **weight,cudastreams *cudas);
void scuda_ann_forward(kernel_ann *kernel,cudastreams *cudas);
double scuda_ann_error(kernel_ann *kernel,double *train,cudastreams *cudas);
double scuda_ann_train(kernel_ann *kernel,double *train,cudastreams *cudas);
void scuda_ann_raz_momentum(kernel_ann *kernel,cudastreams *cudas);
double scuda_ann_train_momentum(kernel_ann *kernel,double *train,double moment,
    cudastreams *cudas);

#if __cplusplus
}
#endif

#endif /*CUDA_ANN_H*/
