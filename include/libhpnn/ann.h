/*
+++ libhpnn - High Performance Neural Network library - file: ann.h +++
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
#ifndef ANN_H
#define ANN_H

#define _2D_IDX(len,j,i) (len)*(j)+i

#ifndef ANN_UNROLL 
#define ANN_UNROLL 4
#endif /*ANN_UNROLL*/

#define DBG_TRACE(array,N) do{\
    acc=0.;\
    for(rdx=0;rdx<(N);rdx++) acc+=(array)[rdx];\
    fprintf(stdout,"#DBG: acc=%.15f\n",acc);\
}while(0)

typedef struct {
    UINT n_neurons;     /*number of neurons*/
    UINT n_inputs;      /*number of inputs*/
    DOUBLE *weights;    /*weights for this layer*/
    DOUBLE *vec;        /*output of this layer*/
} layer_ann;

typedef struct kann{
    CHAR *name;         /*ANN name*/
    UINT n_inputs;      /*number of inputs*/
    DOUBLE *in;         /*input array*/
    UINT n_hiddens;     /*number of hidden layers*/
    layer_ann *hiddens; /*hidden layers*/
    UINT n_outputs;     /*number of outputs*/
    layer_ann output;   /*output layer*/
    DOUBLE **dw;        /*weight momentum (when relevant)*/
    UINT max_index;     /*maximum array index*/
    DOUBLE *tmp_cpu;    /*temporary array (CPU)*/
    DOUBLE *tmp_gpu;    /*temporary array (GPU))*/
    struct kann **kerns;/*multiple allocation (when relevant)*/
} kernel_ann;

/*functions*/
BOOL ann_kernel_free(kernel_ann *kernel);
BOOL ann_kernel_allocate(kernel_ann *kernel,UINT n_inputs,UINT n_hiddens,
                         UINT *h_neurons, UINT n_outputs);
kernel_ann *ann_load(CHAR *f_kernel);
kernel_ann *ann_generate(UINT *seed,UINT n_inputs,UINT n_hiddens,
                         UINT n_outputs,UINT *hiddens);
void ann_dump(kernel_ann *kernel,FILE *out);
BOOL ann_validate_kernel(kernel_ann *kernel);
DOUBLE ann_act(DOUBLE x);
DOUBLE ann_dact(DOUBLE y);
void ann_kernel_run(kernel_ann *kernel);
DOUBLE ann_kernel_train(kernel_ann *kernel,const DOUBLE *train);
void ann_momentum_init(kernel_ann *kernel);
void ann_raz_momentum(kernel_ann *kernel);
void ann_momentum_free(kernel_ann *kernel);
DOUBLE ann_kernel_train_momentum(kernel_ann *kernel,
    const DOUBLE *train,DOUBLE alpha);
DOUBLE ann_train_BP(kernel_ann *kernel,
    DOUBLE *train_in,DOUBLE *train_out,DOUBLE delta);
DOUBLE ann_train_BPM(kernel_ann *kernel,
    DOUBLE *train_in,DOUBLE *train_out,DOUBLE alpha,DOUBLE delta);
#endif /*ANN_H*/
