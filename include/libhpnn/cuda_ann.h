/*
 * cuda_ann.h
 *
 * Copyright (C) 2019 - Hubert Valencia
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */
#ifndef CUDA_ANN_H
#define CUDA_ANN_H

void scuda_ann_allocate(_kernel *kernel,cudastreams *cudas);
void scuda_ann_weights_C2G(_kernel *kernel,cudastreams *cudas);
void scuda_ann_weights_G2C(_kernel *kernel,cudastreams *cudas);

void scuda_ann_forward(_kernel *kernel,cudastreams *cudas);
double scuda_ann_error(_kernel *kernel,double *train,cudastreams *cudas);
double scuda_ann_train(_kernel *kernel,double *train,cudastreams *cudas);
void scuda_ann_raz_momentum(_kernel *kernel,cudastreams *cudas);
double scuda_ann_train_momentum(_kernel *kernel,double *train,double moment,cudastreams *cudas);

#endif /*CUDA_ANN_H*/
