# cython: profile=True
# cython: cdivision=True
from libc.string cimport memset, memcpy

cimport numpy as np

from cymem.cymem cimport Pool
from preshed.maps cimport MapStruct as MapC
from preshed.maps cimport map_init as Map_init
from preshed.maps cimport map_set as Map_set
from preshed.maps cimport map_get as Map_get
from preshed.maps cimport map_iter as Map_iter
from preshed.maps cimport key_t

from .eg cimport Example

from .structs cimport NeuralNetC
from .structs cimport IteratorC
from .structs cimport FeatureC
from .structs cimport ExampleC

from .blas cimport MatVec, VecVec, Vec

from .structs cimport do_iter_t
from .structs cimport do_feed_fwd_t
from .structs cimport do_end_fwd_t
from .structs cimport do_begin_fwd_t
from .structs cimport do_begin_bwd_t
from .structs cimport do_end_bwd_t
from .structs cimport do_feed_bwd_t
from .structs cimport do_update_t

from .blas cimport MatMat


import numpy


cdef extern from "math.h" nogil:
    float expf(float x)
    float sqrtf(float x)


DEF EPS = 0.000001 
DEF ALPHA = 1.0


cdef class NeuralNet:
    cdef readonly Pool mem
    cdef NeuralNetC c

    def __init__(self, widths, embed=None, float eta=0.005, float eps=1e-6,
                 float mu=0.2, float rho=1e-4, float bias=0.0, float alpha=0.0):
        self.mem = Pool()
        NN.init(&self.c, self.mem, widths, eta, eps, mu, rho, bias, alpha)

    def __call__(self, features):
        cdef Example eg = self.eg
        eg.wipe(self.widths)
        eg.set_features(features)
        NN.predict_example(&eg.c,
            &self.c)
        return eg
   
    #def train(self, features, y):
    #    memset(self.c.gradient,
    #        0, sizeof(self.c.gradient[0]) * self.c.nr_weight)
    #    cdef Example eg = self.eg
    #    eg.wipe(self.widths)
    #    eg.set_features(features)
    #    eg.set_label(y)

    #    NN.predict_example(&eg.c, &self.c)
    #    NN.insert_embeddings(self.c.embeds, self.mem,
    #        &eg.c)
    #    NN.insert_embeddings(self.c.opt.embed_params, self.mem,
    #        &eg.c)
    #    NN.update_dense(&self.c, self.c.gradient, &eg.c)
    #    NN.update_sparse(&self.c, self.c.gradient, &eg.c)
    #    return eg
 
    def Example(self, input_, label=None):
        if isinstance(input_, Example):
            return input_
        return Example(self.widths, input_, label)

    property weights:
        def __get__(self):
            cdef np.npy_intp shape[1]
            shape[0] = <np.npy_intp> self.c.nr_weight
            return np.PyArray_SimpleNewFromData(1, shape, np.NPY_FLOAT, self.c.weights)
            
        def __set__(self, weights):
            assert len(weights) == self.c.nr_weight
            for i, weight in enumerate(weights):
                self.c.weights[i] = weight

    property layers:
        def __get__(self):
            weights = self.weights
            cdef IteratorC it
            it.i = 0
            while NN.iter(&it, self.c.widths, self.c.nr_layer-1, 1):
                yield (weights[it.W:it.bias], weights[it.bias:it.gamma])

    property widths:
        def __get__(self):
            return tuple(self.c.widths[i] for i in range(self.c.nr_layer))

    property layer_l1s:
        def __get__(self):
            for W, bias in self.layers:
                w_l1 = sum(abs(w) for w in W) / len(W)
                bias_l1 = sum(abs(w) for w in W) / len(bias)
                yield w_l1, bias_l1

    property gradient:
        def __get__(self):
            return [self.c.gradient[i] for i in range(self.c.nr_weight)]

    property l1_gradient:
        def __get__(self):
            cdef int i
            cdef float total = 0.0
            for i in range(self.c.nr_weight):
                if self.c.gradient[i] < 0:
                    total -= self.c.gradient[i]
                else:
                    total += self.c.gradient[i]
            return total / self.c.nr_weight

    property embeddings:
        def __get__(self):
            cdef int i = 0
            cdef int j = 0
            cdef int k = 0
            cdef key_t key
            cdef void* value
            for i in range(self.c.nr_embed):
                j = 0
                while Map_iter(self.c.sparse_weights[i], &j, &key, &value):
                    emb = <float*>value
                    yield key, [emb[k] for k in range(self.c.embed_lengths[i])]

    property nr_layer:
        def __get__(self):
            return self.c.nr_layer
    property nr_weight:
        def __get__(self):
            return self.c.nr_weight
    property nr_out:
        def __get__(self):
            return self.c.widths[self.c.nr_layer-1]
    property nr_in:
        def __get__(self):
            return self.c.widths[0]

    #property eta:
    #    def __get__(self):
    #        return self.c.eta
    #    def __set__(self, eta):
    #        self.c.eta = eta
    #property rho:
    #    def __get__(self):
    #        return self.c.rho
    #    def __set__(self, rho):
    #        self.c.rho = rho
    #property eps:
    #    def __get__(self):
    #        return self.c.eps
    #    def __set__(self, eps):
    #        self.c.eps = eps


cdef class NN:
    @staticmethod
    cdef void init(
        NeuralNetC* nn,
        Pool mem,
            widths,
            float eta=0.005,
            float eps=1e-6,
            float mu=0.2,
            float rho=1e-4,
            float bias=0.0,
            float alpha=0.0
    ) except *:
        nn.nr_layer = len(widths)
        nn.widths = <int*>mem.alloc(nn.nr_layer, sizeof(widths[0]))
        cdef int i
        for i, width in enumerate(widths):
            nn.widths[i] = width

        nn.nr_weight = 0
        for i in range(nn.nr_layer-1):
            nn.nr_weight += NN.nr_weight(nn.widths[i+1], nn.widths[i])
        nn.weights = <float*>mem.alloc(nn.nr_weight, sizeof(nn.weights[0]))
        nn.gradient = <float*>mem.alloc(nn.nr_weight, sizeof(nn.weights[0]))
        nn.momentum = <float*>mem.alloc(nn.nr_weight, sizeof(nn.weights[0]))
        nn.averages = <float*>mem.alloc(nn.nr_weight, sizeof(nn.weights[0]))
        
        nn.sparse_weights = <MapC**>mem.alloc(nn.nr_embed, sizeof(void*))
        nn.sparse_gradient = <MapC**>mem.alloc(nn.nr_embed, sizeof(void*))
        nn.sparse_momentum = <MapC**>mem.alloc(nn.nr_embed, sizeof(void*))
        nn.sparse_averages = <MapC**>mem.alloc(nn.nr_embed, sizeof(void*))

        nn.embed_offsets = <int*>mem.alloc(nn.nr_embed, sizeof(nn.embed_offsets[0]))
        nn.embed_lengths = <int*>mem.alloc(nn.nr_embed, sizeof(nn.embed_offsets[0]))
        nn.embed_defaults = <float**>mem.alloc(nn.nr_embed, sizeof(nn.embed_offsets[0]))

        for i in range(nn.nr_embed):
            nn.embed_defaults[i] = <float*>mem.alloc(nn.embed_lengths[i],
                                                     sizeof(nn.embed_defaults[i][0]))
        
        cdef IteratorC it
        it.i = 0
        while NN.iter(&it, nn.widths, nn.nr_layer-1, 1):
            # Allocate arrays for the normalizers
            # Don't initialize the softmax weights
            if (it.i+1) >= nn.nr_layer:
                break
            he_normal_initializer(&nn.weights[it.W],
                fan_in, it.nr_out * it.nr_in)
            constant_initializer(&nn.weights[it.bias],
                bias, it.nr_out)
            he_normal_initializer(&nn.weights[it.gamma],
               1, it.nr_out)
            fan_in = it.nr_out

    @staticmethod
    cdef inline int iter(IteratorC* it, const int* widths, int nr_layer, int inc) nogil:
        it.nr_out = widths[it.i+1]
        it.nr_in = widths[it.i]
        it.W = 0
        cdef int i
        for i in range(it.i):
            it.W += NN.nr_weight(widths[i+1], widths[i])
        it.bias = it.W + (it.nr_out * it.nr_in)
        it.gamma = it.bias + it.nr_out
        it.beta = it.gamma + it.nr_out

        it.below = it.i * 2
        it.here = it.below + 1
        it.above = it.below + 2

        it.Ex = it.here
        it.Vx = it.above
        it.E_dXh = it.here
        it.E_dXh_Xh = it.above
        it.i += inc
        if nr_layer >= it.i and it.i >= 0:
            return True
        else:
            return False

    @staticmethod
    cdef int nr_weight(int nr_out, int nr_in) nogil:
        return nr_out * nr_in + nr_out * 3

    @staticmethod
    cdef void predict_example(ExampleC* eg, const NeuralNetC* nn) nogil:
        NN.forward(eg.fwd_state,
            eg.features, eg.nr_feat, nn)
        Example.set_scores(eg, eg.fwd_state[nn.nr_layer*2-2])

    @staticmethod
    cdef void train_example(NeuralNetC* nn, Pool mem, ExampleC* eg) except *:
        memset(nn.gradient,
            0, sizeof(nn.gradient[0]) * nn.nr_weight)
        NN.predict_example(eg,
            nn)
        insert_sparse(nn.sparse_weights, mem,
            nn.embed_lengths, nn.embed_offsets, nn.embed_defaults,
            eg.features, eg.nr_feat)
        # N.B. If we switch the insert_sparse API away from taking this
        # defaults argument, ensure that we allow zero-initialization option.
        insert_sparse(nn.sparse_momentum, mem,
            nn.embed_lengths, nn.embed_offsets, nn.embed_defaults,
            eg.features, eg.nr_feat)
        NN.update(nn, eg)
     
    @staticmethod
    cdef void forward(
        float** fwd,
            const FeatureC* feats,
            int nr_feat,
            const NeuralNetC* nn
    ) nogil:
        set_input(fwd[0],
            feats, nr_feat, nn.embed_lengths, nn.embed_offsets,
            nn.embed_defaults, nn.sparse_weights) 
        forward(fwd,
            nn.widths, nn.nr_layer, nn.weights, nn.nr_weight, &nn.alpha, nn.iterate,
            nn.begin_fwd, nn.feed_fwd, nn.end_fwd)

    @staticmethod
    cdef void backward(
        float* bwd,
            const float* fwd,
            const float* costs,
            const NeuralNetC* nn
    ) nogil:
        backward(bwd,
            fwd, nn.widths, nn.nr_layer, nn.weights, nn.nr_weight, costs,
            &nn.alpha, nn.iterate, nn.begin_bwd, nn.feed_bwd, nn.end_bwd)

    @staticmethod
    cdef void update(
        NeuralNetC* nn,
            const ExampleC* eg
    ) nogil:
        dense_update(nn.weights, nn.gradient, nn.momentum,
            nn.nr_weight, eg.bwd_state, eg.fwd_state, nn.widths, nn.nr_layer,
            &nn.alpha, nn.iterate, nn.update)
        sparse_update(
            nn.sparse_weights,
            nn.sparse_momentum,
            nn.gradient,
                eg.bwd_state[0],
                nn.embed_lengths,
                nn.embed_offsets,
                eg.bwd_state,
                eg.features,
                eg.nr_feat,
                &nn.alpha,
                nn.update)


cdef void forward(
    float** fwd,
        const int* widths,
        int nr_layer,
        const float* weights,
        int nr_weight,
        const void* _ext,
        do_iter_t iterate,
        do_begin_fwd_t begin_fwd,
        do_feed_fwd_t feed_fwd,
        do_end_fwd_t end_fwd
) nogil:
    cdef IteratorC it = begin_fwd(fwd,
            widths, nr_layer, weights, nr_weight, _ext)
    while iterate(<void*>&it, widths, nr_layer-2, 1):
        feed_fwd(fwd,
            widths, nr_layer, weights, nr_weight, _ext, &it)
    end_fwd(&it, fwd,
        widths, nr_layer, weights, nr_weight, _ext)


cdef void backward(
    float* bwd,
        const float* fwd,
        const int* widths,
        int nr_layer,
        const float* weights,
        int nr_weight,
        const float* costs,
        const void* _ext,
        do_iter_t iterate,
        do_begin_bwd_t begin_bwd,
        do_feed_bwd_t feed_bwd,
        do_end_bwd_t end_bwd
) nogil:
    '''Iteratatively apply the step_bwd function, to back-prop through the network.
    Fills partial derivatives for each layer into bwd, so that the gradient can
    be computed. Updates estimates of normalization parameters in b_norms.'''
    cdef IteratorC it = begin_bwd(bwd,
            fwd, widths, nr_layer, weights, nr_weight, _ext)
    while iterate(&it, widths, nr_layer, -1):
        feed_bwd(bwd,
            fwd, widths, nr_layer, weights, nr_weight, &it, _ext)
    end_bwd(&it, bwd,
        fwd, widths, nr_layer, weights, nr_weight, _ext)


cdef void dense_update(
    float* weights,
    float* gradient,
    float* moments,
        int nr_weight,
        const float* const* bwd,
        const float* const* fwd,
        const int* widths,
        int nr_layer,
        const void* _ext,
        do_iter_t iterate,
        do_update_t do_update
) nogil:
    cdef IteratorC it
    it.i = 0
    while iterate(&it, widths, nr_layer, 1):
        MatMat.add_outer_i(&gradient[it.W], # Gradient of synapse weights
            bwd[it.above], fwd[it.below], it.nr_out, it.nr_in)
        VecVec.add_i(&gradient[it.bias], # Gradient of bias weights
            bwd[it.above], 1.0, it.nr_out)
        MatMat.add_outer_i(&gradient[it.gamma], # Gradient of gammas
            bwd[it.here], fwd[it.here], it.nr_out, 1)
        VecVec.add_i(&gradient[it.beta], # Gradient of betas
            bwd[it.here], 1.0, it.nr_out)
    do_update(weights, gradient, moments,
        nr_weight, _ext)


cdef void sparse_update(
    MapC** weights_tables,
    MapC** moments_tables,
    float* tmp,
        const float* gradient,
        const int* lengths,
        const int* offsets,
        const float* const* defaults,
        const FeatureC* feats,
        int nr_feat,
        const void* _ext,
        do_update_t do_update,
) nogil:
    for f in range(nr_feat):
        idx = feats[f].i
        weights = <float*>Map_get(weights_tables[idx], feats[f].key)
        moments = <float*>Map_get(moments_tables[idx], feats[f].key)
        # These should never be null.
        if weights is not NULL and moments is not NULL:
            # Copy the gradient into the temp buffer, so we can modify it in-place
            memcpy(&tmp[offsets[idx]],
                &gradient[offsets[idx]], sizeof(float) * lengths[idx])
            Vec.mul_i(&tmp[offsets[idx]],
                feats[f].value, lengths[idx])
            do_update(&weights[offsets[idx]], &moments[offsets[idx]], &tmp[offsets[idx]],
                lengths[idx], _ext)


cdef void dotPlus_normalize_dotPlus_ELU(
    float* fwd,
        const int* widths,
        int nr_layer,
        const float* weights,
        int nr_weight,
        const void* _it,
        const void* _ext
) nogil:
    it = <const IteratorC*>_it
    hyper_params = <const float*>_ext
    cdef float* here = fwd + it.here
    cdef float* above = fwd + it.above
    cdef float* Ex = fwd + it.Ex
    cdef float* Vx = fwd + it.Vx
    cdef const float* below = fwd + it.below
    cdef const float* W = weights + it.W
    cdef const float* bias = weights + it.bias
    cdef const float* gamma = weights + it.gamma
    cdef const float* beta = weights + it.beta
    cdef int nr_in = it.nr_in
    cdef int nr_out = it.nr_out
    cdef float ema_speed = hyper_params[0]
    dot_plus(here,
        below, W, bias, nr_out, nr_in)
    normalize(here, Ex, Vx,
        nr_out, ema_speed) 
    dot_plus(above,
        here, gamma, beta, nr_out, 1)
    ELU(above,
        nr_out)


cdef void dELU_dDot_dNormalize_dDot(
    float* bwd,
        const float* fwd,
        const int* widths,
        int nr_layer,
        const float* weights,
        int nr_weight,
        const void* _it,
        const void* _ext
) nogil:
    it = <const IteratorC*>_it
    hyper_params = <const float*>_ext
    cdef float* dX = &bwd[it.below]
    cdef float* dXh = &bwd[it.here]
    cdef float* dY = &bwd[it.above]
    cdef float* E_dXh = &bwd[it.E_dXh]
    cdef float* E_dXh_Xh = &bwd[it.E_dXh_Xh]
    cdef const float* Y = &fwd[it.above]
    cdef const float* Xh = &fwd[it.here]
    cdef const float* Vx = &fwd[it.Vx]
    cdef const float* W = &weights[it.W]
    cdef const float* gamma = &weights[it.gamma]
    cdef int nr_out = it.nr_out
    cdef int nr_in = it.nr_in
    cdef float ema_speed = hyper_params[0]
    d_ELU(dY,
        Y, nr_out) # Y = ELU(dot(G, BN(W*x+b))), i.e. our layer's final output
    d_dot(dXh,
        dY, gamma, nr_out, 1)
    d_normalize(dXh, E_dXh, E_dXh_Xh,
        Xh, Vx, nr_out, ema_speed)
    d_dot(dX,
        dXh, W, nr_out, nr_in)


cdef void dot_plus(
    float* out,
        const float* in_,
        const float* W,
        const float* bias,
        int nr_out,
        int nr_in
) nogil:
    MatVec.dot(out,
        W, in_, nr_out, nr_in)
    VecVec.add_i(out,
        bias, 1.0, nr_out)


cdef void sparse_dot_plus(
    float* out,
        const FeatureC* feats,
        const MapC* const* Ws,
        const float* bias,
        int nr_out,
        int nr_feat
) nogil:
    for i in range(nr_feat):
        W = Ws[feats[i].i]
        if W is not NULL: # Shouldn't be NULL
            row = <const float*>Map_get(W, feats[i].key)
            if row is not NULL: # Can be NULL
                VecVec.add_i(out,
                    row, feats[i].value, nr_out)
    VecVec.add_i(out,
        bias, 1.0, nr_out)


cdef void d_dot(
    float* btm_diff,
        const float* top_diff,
        const float* W,
        int nr_out,
        int nr_wide
) nogil:
    MatVec.T_dot(btm_diff,
        W, top_diff, nr_out, nr_wide)


cdef void ELU(float* out, int nr_out) nogil:
    cdef int i
    for i in range(nr_out):
        if out[i] < 0:
            out[i] = ALPHA * (expf(out[i]) - 1)


cdef void d_ELU(float* delta, const float* signal_out, int n) nogil:
    # Backprop the ELU transformation
    # Note that this is over the function _output_, not the function
    # _input_!
    for i in range(n):
        if signal_out[i] < 0:
            delta[i] *= signal_out[i] + ALPHA


cdef void normalize(
    float* x,
    float* Ex,
    float* Vx,
        int n,
        float alpha
) nogil:
    # Upd EMA estimate of mean and variance
    # See eq at the end of this:
    # http://nfs-uxsup.csx.cam.ac.uk/~fanf2/hermes/doc/antiforgery/stats.pdf
    cdef int i
    cdef float diff
    cdef float incr
    for i in range(n):
        diff = x[i] - Ex[i]
        incr = alpha * diff
        Vx[i] = (1.0 - alpha) * (Vx[i] + diff * incr)
        Ex[i] += incr
    # Normalize
    for i in range(n):
        x[i] = (x[i] - Ex[i]) / sqrtf(Vx[i] + EPS)


cdef void d_normalize(
    float* bwd,
    float* E_dEdXh,
    float* E_dEdXh_dot_Xh,
        const float* Xh,
        const float* Vx,
        int n,
        float alpha
) nogil:
    # Update EMA estimate of mean(dL/dX_hat)
    Vec.mul_i(E_dEdXh,
        alpha, n)
    VecVec.add_i(E_dEdXh,
        bwd, 1-alpha, n)
    # Update EMA estimate of mean(dE/dX_hat \cdot X_hat)
    Vec.mul_i(E_dEdXh_dot_Xh,
        alpha, n)
    for i in range(n):
        E_dEdXh_dot_Xh[i] += (1-alpha) * bwd[i] * Xh[i]
    # Simplification taken from Caffe, I think by cdoersch
    # if X' = (X-mean(X))/sqrt(var(X)+eps), then
    # dE/dX =
    #   (dE/dXh - mean(dE/dXh) - mean(dE/dXh * Xh) * Xh)
    #     ./ sqrt(var(X) + eps)
    # bwd is dE/dXh to start with. We change it to dE/dX in-place.
    for i in range(n):
        bwd[i] -= E_dEdXh[i] - E_dEdXh_dot_Xh[i] * Xh[i]
        bwd[i] /= sqrtf(Vx[i] + EPS)


cdef void softmax(
    float* out,
        int nr_out
) nogil:
    #w = exp(w - max(w))
    Vec.add_i(out,
        -Vec.max(out, nr_out), nr_out)
    Vec.exp_i(out,
        nr_out)
    #w = w / sum(w)
    cdef float norm = Vec.sum(out, nr_out)
    if norm != 0:
        Vec.div_i(out,
            norm, nr_out)


cdef void d_log_loss(
    float* loss,
        const float* costs,
        const float* scores,
        int nr_out
) nogil:
    # This assumes only one true class
    cdef int i
    for i in range(nr_out):
        loss[i] = scores[i] - (costs[i] == 0)


cdef void set_input(
    float* out,
        const FeatureC* feats,
        int nr_feat,
        int* lengths,
        int* offsets,
        const float* const* defaults,
        const MapC* const* tables,
) nogil:
    for f in range(nr_feat):
        emb = <const float*>Map_get(tables[feats[f].i], feats[f].key)
        if emb == NULL:
            emb = defaults[feats[f].i]
        VecVec.add_i(out, 
            emb, 1.0, lengths[feats[f].i])


cdef void insert_sparse(
    MapC** tables,
    Pool mem,
        const int* lengths, 
        const int* offsets,
        const float* const* defaults,
        const FeatureC* feats,
        int nr_feat
) except *:
    for f in range(nr_feat):
        emb = <float*>Map_get(tables[feats[f].i], feats[f].key)
        if emb is NULL:
            emb = <float*>mem.alloc(lengths[feats[f].i], sizeof(emb[0]))
            # TODO: Which is better here???
            # N.B.: Careful enabling this. It can break use of this function to
            # initialize things that should be zeroed.
            #Initializer.normal(emb,
            #    0.0, 1.0, length)
            # We initialize with the defaults here so that we only have
            # to insert during training --- on the forward pass, we can
            # set default. But if we're doing that, the back pass needs
            # to be dealing with the same representation.
            memcpy(emb,
                defaults[feats[f].i], sizeof(emb[0]) * lengths[feats[f].i])
            Map_set(mem, tables[feats[f].i],
                feats[f].key, emb)


cdef void he_normal_initializer(float* weights, int fan_in, int n) except *:
    # See equation 10 here:
    # http://arxiv.org/pdf/1502.01852v1.pdf
    values = numpy.random.normal(loc=0.0, scale=numpy.sqrt(2.0 / float(fan_in)), size=n)
    for i, value in enumerate(values):
        weights[i] = value


cdef void constant_initializer(float* weights, float value, int n) nogil:
    for i in range(n):
        weights[i] = value
