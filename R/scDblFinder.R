#' scDblFinder
#' 
#' Identification of heterotypic (or neotypic) doublets in single-cell RNAseq 
#' using cluster-based generation of artifical doublets.
#'
#' @param sce A \code{\link[SummarizedExperiment]{SummarizedExperiment-class}},
#' \code{\link[SingleCellExperiment]{SingleCellExperiment-class}}, or array of
#' counts.
#' @param artificialDoublets The approximate number of artificial doublets to 
#' create. If \code{NULL}, will be the maximum of the number of cells or 
#' \code{5*nbClusters^2}.
#' @param clusters The optional cluster assignments (if omitted, will run 
#' clustering). This is used to make doublets more efficiently. \code{clusters} 
#' should either be a vector of labels for each cell, or the name of a colData 
#' column of \code{sce}. Alternatively, if it is a single integer, will 
#' determine how many clusters to create (using k-means clustering). This 
#' options should be used when distinct subpopulations are not expected in the 
#' data (e.g. trajectories).
#' @param samples A vector of the same length as cells (or the name of a column 
#' of \code{colData(x)}), indicating to which sample each cell belongs. Here, a 
#' sample is understood as being processed independently. If omitted, doublets 
#' will be searched for with all cells together. If given, doublets will be 
#' searched for independently for each sample, which is preferable if they 
#' represent different captures. If your samples were multiplexed using cell
#' hashes, want you want to give here are the different batches/wells (i.e. 
#' independent captures, since doublets cannot arise across them) rather
#' than biological samples.
#' @param trajectoryMode Logical; whether to generate doublets in trajectory 
#' mode (i.e. for datasets with gradients rather than separated subpopulations).
#' See \code{vignette("scDblFinder")} for more details.
#' @param knownDoublets An optional logical vector of known doublets (e.g. 
#' through cell barcodes), or the name of a colData column of `sce` containing
#' that information.
#' @param use.cxds Logical; whether to use the `cxds` scores in addition to 
#' information from artificial/known doublets as part of the predictors.
#' @param nfeatures The number of top features to use (default 1000)
#' @param dims The number of dimensions used.
#' @param dbr The expected doublet rate. By default this is assumed to be 1\% 
#' per thousand cells captured (so 4\% among 4000 thousand cells), which is 
#' appropriate for 10x datasets. Corrections for homeotypic doublets will be
#' performed on the given rate.
#' @param dbr.sd The uncertainty range in the doublet rate, interpreted as
#' a +/- around `dbr`. During thresholding, deviation from the expected doublet
#' rate will be calculated from these boundaries, and will be considered null 
#' within these boundaries.
#' @param k Number of nearest neighbors (for KNN graph). If more than one value
#' is given, the doublet density will be calculated at each k (and other values
#' at the highest k), and all the information will be used by the classifier.
#' If omitted, a reasonable set of values is used.
#' @param includePCs The index of principal components to include in the 
#' predictors (e.g. `includePCs=1:2`).
#' @param propRandom The proportion of the artificial doublets which 
#' should be made of random cells (as opposed to inter-cluster combinations).
#' @param propMarkers The proportion of features to select based on marker 
#' identification.
#' @param returnType Either "sce" (default), "table" (to return the table of 
#' cell attributes including artificial doublets), or "full" (returns an SCE
#' object containing both the real and artificial cells.
#' @param score Score to use for final classification.
#' @param metric Error metric to optimize during training (e.g. 'merror', 
#' 'logloss', 'auc', 'aucpr').
#' @param nrounds Maximum rounds of boosting. If NULL, will be determined
#' through cross-validation. When the training is based only on simulated 
#' doublets, we generally find lower limits to outperform cross-validation.
#' @param max_depth Maximum depth of decision trees
#' @param iter A positive integer indicating the number of scoring iterations
#' (ignored if `score` isn't based on classifiers). At each iteration, real 
#' cells that would be called as doublets are excluding from the training, and
#' new scores are calculated. Recommended values are 1 or 2.
#' @param threshold Logical; whether to threshold scores into binary doublet 
#' calls
#' @param verbose Logical; whether to print messages and the thresholding plot.
#' @param BPPARAM Used for multithreading when splitting by samples (i.e. when 
#' `samples!=NULL`); otherwise passed to eventual PCA and K/SNN calculations.
#' @param ... further arguments passed to \code{\link{getArtificialDoublets}}.
#'
#' @return The \code{sce} object with several additional colData columns, in 
#' particular `scDblFinder.score` (the final score used) and `scDblFinder.class` 
#' (whether the cell is called as 'doublet' or 'singlet'). See 
#' \code{vignette("scDblFinder")} for more details; for alternative return 
#' values, see the `returnType` argument.
#' 
#' @details
#' This function generates artificial doublets from clusters of real cells, 
#' evaluates their prevalence in the neighborhood of each cells, and uses this 
#' along with additional features to classify doublets. The approach is 
#' complementary to doublets identified via cell hashes and SNPs in multiplexed
#' samples: the latter can identify doublets formed by cells of the same type
#' from two samples, which are nearly undistinguishable from real cells 
#' transcriptionally, but cannot identify doublets made by cells of the 
#' same sample. See \code{vignette("scDblFinder")} for more details on the 
#' method.
#' 
#' When multiple samples/captures are present, they should be specified using 
#' the \code{samples} argument. Although the classifier will be trained 
#' globally, thresholding and the more computationally-intensive steps will be 
#' performed separately for each sample (in parallel if \code{BPPARAM} is 
#' given).
#'
#' When inter-sample doublets are available, they can be provided to 
#' `scDblFinder` through the \code{knownDoublets} argument to improve the 
#' identification of further doublets.
#' 
#' @import SingleCellExperiment BiocParallel xgboost
#' @importFrom SummarizedExperiment colData<- assayNames
#' @importFrom scuttle normalizeCounts
#' @importFrom scater runPCA
#' @importFrom methods is
#' @importFrom DelayedArray as.matrix
#' @importFrom BiocNeighbors findKNN
#' @importFrom BiocSingular IrlbaParam
#' 
#' @examples
#' library(SingleCellExperiment)
#' sce <- mockDoubletSCE()
#' sce <- scDblFinder(sce, dbr=0.1)
#' table(truth=sce$type, call=sce$scDblFinder.class)
#' 
#' @export
#' @rdname scDblFinder
#' @import SingleCellExperiment
#' @importFrom SummarizedExperiment rowData<-
#' @importFrom BiocParallel SerialParam bpnworkers
scDblFinder <- function( sce, clusters=NULL, samples=NULL, trajectoryMode=FALSE,
                         artificialDoublets=NULL, knownDoublets=NULL, 
                         use.cxds=TRUE, nfeatures=1000, dims=20, dbr=NULL, 
                         dbr.sd=0.015, k=NULL, includePCs=1:5, propRandom=0.1,
                         propMarkers=0, returnType=c("sce","table","full"),
                         score=c("xgb","xgb.local.optim","weighted","ratio"),
                         metric="aucpr", nrounds=50, max_depth=5, iter=1, 
                         threshold=TRUE, verbose=is.null(samples), 
                         BPPARAM=SerialParam(), ...
                        ){
  ## check arguments
  sce <- .checkSCE(sce)
  score <- match.arg(score)
  returnType <- match.arg(returnType)
  if(!is.null(clusters)){
    if(length(clusters)>1 || !is.numeric(clusters))
      clusters <- .checkColArg(sce, clusters)
  }
  knownDoublets <- .checkColArg(sce, knownDoublets)
  samples <- .checkColArg(sce, samples)
  .checkPropArg(propMarkers)
  .checkPropArg(propRandom)
  .checkPropArg(dbr.sd)

  ## if clusters are given, it's more efficient to do feature selection before
  ## eventually splitting the dataset
  if(!is.null(clusters) && length(clusters)>1){
    sel_features <- selFeatures(sce, clusters, nfeatures=nfeatures, 
                                propMarkers=propMarkers)
  }else{
    sel_features <- row.names(sce)
  }
  
  if(!is.null(samples)){
    ## splitting by samples
    if(returnType=="full") 
        warning("`returnType='full'` ignored when splitting by samples")
    cs <- split(seq_along(samples), samples, drop=TRUE)
    names(nn) <- nn <- names(cs)
    ## run scDblFinder individually, without classification
    d <- bplapply(nn, BPPARAM=BPPARAM, FUN=function(n){ 
      x <- cs[[n]]
      if(!is.null(clusters) && length(clusters)>1) clusters <- clusters[x]
      tryCatch(scDblFinder(sce[sel_features,x], clusters=clusters, 
                  knownDoublets=knownDoublets, dims=dims, dbr=dbr, 
                  dbr.sd=dbr.sd, artificialDoublets=artificialDoublets, k=k, 
                  nfeatures=nfeatures, propRandom=propRandom, includePCs=c(),
                  propMarkers=propMarkers, trajectoryMode=trajectoryMode, 
                  returnType="table", threshold=FALSE, score="weighted", 
                  verbose=FALSE, ...),
               error=function(e){
                 stop("An error occured while processing sample '",n,"':\n", e)
               })
    })
    ## aggregate the property tables
    cn <- table(unlist(lapply(d, colnames)))
    cn <- names(cn)[cn==length(d)]
    ss <- factor(rep(seq_along(names(d)),vapply(d,nrow,integer(1))), 
                 levels=seq_along(names(d)), labels=names(d))
    d <- do.call(rbind, lapply(d, FUN=function(x){
      x$total.prop.real <- sum(x$type=="real",na.rm=TRUE)/nrow(x)
      x[,cn]
    }))
    d$sample <- ss
    ## score and thresholding
    d <- .scDblscore(d, scoreType=score, threshold=threshold, dbr=dbr, 
                     dbr.sd=dbr.sd, max_depth=max_depth, nrounds=nrounds, 
                     iter=iter, BPPARAM=BPPARAM, verbose=verbose, metric=metric)
    if(returnType=="table") return(d)
    return(.scDblAddCD(sce, d))
  }
  
  ## Handling a single sample 
  
  if(ncol(sce)<100)
    warning("scDblFinder might not work well with very low numbers of cells.")
  if(verbose && ncol(sce)>25000)
    warning("You are trying to run scDblFinder on a very large number of ",
            "cells. If these are from different captures, please specify this",
            " using the `samples` argument.", immediate=TRUE)

  if(is.null(k)){ ## reasonble sets of ks (for KNN)
      k <- c(3,10,20)
      if((kmax <- max(ceiling(sqrt(ncol(sce)/6)),20))>=30) k <- c(k,kmax)
  }
  
  orig <- sce
  wDbl <- c()
  
  ## if known doublets are given, we need to treat them separately
  if(!is.null(knownDoublets) && length(wDbl <- which(knownDoublets))>0){
    sce$knownDoublet <- knownDoublets
    sce.dbl <- sce[,wDbl,drop=FALSE]
    sce <- sce[,-wDbl,drop=FALSE]
    if(!is.null(clusters) && length(clusters)>1){
      clusters.dbl <- clusters[wDbl]
      clusters <- clusters[-wDbl]
      if(is.factor(clusters)) clusters <- droplevels(clusters)
    }
  }
  
  ## clustering (if not already provided)
  if(is.null(clusters) || length(clusters)==1){
    if(verbose) message("Clustering cells...")
    if(!is.null(clusters)){
      clusters <- fastcluster(sce, ndims=dims, k=clusters, nfeatures=nfeatures,
                    returnType=ifelse(trajectoryMode,"graph","preclusters"),
                    BPPARAM=BPPARAM, verbose=FALSE)
    }else{
      clusters <- fastcluster(sce, ndims=dims, nfeatures=nfeatures,
                              BPPARAM=BPPARAM, verbose=FALSE)
    }
  }else if(trajectoryMode && length(unique(clusters))>1){
    clusters <- list( k=clusters,
      graph=.getMetaGraph(.getDR(sce,ndims=dims,nfeatures=nfeatures),
                          clusters, BPPARAM=BPPARAM) )
  }
  if(is.list(clusters)){
    cl <- clusters$k
  }else{
    cl <- clusters
  }
  nc <- length(unique(cl))
  if(nc==1) stop("Only one cluster generated. Consider specifying `cluster` ",
                 "(e.g. `cluster=10`)")
  if(verbose) message(nc, " clusters")
  
  ## feature selection
  if(length(sel_features)>nfeatures)
    sel_features <- selFeatures(sce[sel_features,], cl, nfeatures=nfeatures, 
                                propMarkers=propMarkers)
  sce <- sce[sel_features,]
  if(length(wDbl)>0) sce.dbl <- sce.dbl[sel_features,]
  
  ## get the artificial doublets
  if(is.null(artificialDoublets))
    artificialDoublets <- min( 25000, max(5000,
                                          ceiling(ncol(sce)*0.6),
                                          10*length(unique(cl))^2 ) )
  if(artificialDoublets<2)
      artificialDoublets <- min(ceiling(artificialDoublets*ncol(sce)),25000)
  
  if(verbose)
    message("Creating ~", artificialDoublets, " artifical doublets...")
  ad <- getArtificialDoublets(as.matrix(counts(sce)), n=artificialDoublets, 
                              clusters=clusters, propRandom=propRandom, ...)

  gc(verbose=FALSE)
  
  ado <- ad$origins
  ad <- ad$counts
  
  no <- ncol(sce) + length(wDbl)
  ado2 <- as.factor(c(rep(NA, no), as.character(ado)))
  src <- factor( rep(1:2, c(no,ncol(ad))), labels = c("real","artificial"))
  ctype <- factor( rep(c(1,2,2), c(ncol(sce),length(wDbl),ncol(ad))), 
                   labels=c("real","doublet") )
  
  if(verbose) message("Dimensional reduction")
  
  e <- counts(sce)
  if(!is.null(wDbl)) e <- cbind(e, counts(sce.dbl))
  e <- cbind(e, ad[row.names(sce),])
  
  # evaluate by library size and non-zero features
  lsizes <- Matrix::colSums(e)
  cxds_score <- NULL
  if(use.cxds) cxds_score <- cxds2(e, whichDbls=which(ctype==2))
  nfeatures <- Matrix::colSums(e>0)
  
  # skip normalization if data is too large
  if(ncol(e)<=50000){
  tryCatch({
      e <- normalizeCounts(e)
    }, error=function(er){
      warning("Error in calculating norm factors:", er)
    })
  }
  
  if(is.null(dims)) dims <- 20
  pca <- tryCatch({
            scater::calculatePCA(e, dims, subset_row=seq_len(nrow(e)),
                                 BSPARAM=BiocSingular::IrlbaParam())
        }, error=function(msg){
            reducedDim( scater::runPCA( SingleCellExperiment(list(logcounts=e)), 
                                        ncomponents=dims, ntop=nrow(e),
                                        BSPARAM=BiocSingular::IrlbaParam()) )
        })
  if(is.list(pca)) pca <- pca$x
  row.names(pca) <- colnames(e)
  
  ex <- getExpectedDoublets(clusters, dbr)
  d <- .evaluateKNN(pca, ctype, ado2, expected=ex, k=k, BPPARAM=BPPARAM, 
                      verbose=verbose)$d
  if(is.list(clusters)) clusters <- clusters$k
  d[colnames(sce),"cluster"] <- clusters
  d$lsizes <- lsizes
  d$nfeatures <- nfeatures
  d$src <- src
  if(use.cxds) d$cxds_score <- cxds_score
  
  ## classify
  d <- .scDblscore(cbind(d, pca[,includePCs,drop=FALSE]), scoreType=score, 
                   threshold=threshold, dbr=dbr, dbr.sd=dbr.sd, nrounds=nrounds,
                   max_depth=max_depth, iter=iter, BPPARAM=BPPARAM,
                   verbose=verbose, metric=metric)

  if(returnType=="table") return(d)
  if(returnType=="full"){
      sce_out <- SingleCellExperiment(list(
          counts=cbind(counts(sce), ad[row.names(sce),])), colData=d)
      reducedDim(sce_out, "PCA") <- pca
      if(is(d,"DataFrame") && !is.null(metadata(d)$scDblFinder.stats)) 
        metadata(sce_out)$scDblFinder.stats <- metadata(d)$scDblFinder.stats
      return(sce_out)
  }
  rowData(orig)$scDblFinder.selected <- row.names(orig) %in% sel_features
  .scDblAddCD(orig, d)
}

#' @importFrom BiocNeighbors AnnoyParam
.evaluateKNN <- function(pca, ctype, origins, expected, k, 
                         BPPARAM=SerialParam(), verbose=TRUE){
  if(verbose) message("Finding KNN...")
  knn <- suppressWarnings(findKNN(pca, max(k), BPPARAM=BPPARAM,
                                  BNPARAM=AnnoyParam()))
  
  if(verbose) message("Evaluating cell neighborhoods...")
  knn$type <- matrix(as.numeric(ctype)[knn$index]-1, nrow=nrow(knn$index))
  knn$orig <- matrix(origins[knn$index], nrow=nrow(knn[[1]]))
  if(any(w <- knn$distance==0))
    knn$distance[w] <- min(knn$distance[knn$distance[,1]>0,1])
  
  md <- max(knn$distance[,1])
  dr <- t(vapply(seq_len(nrow(knn$distance)), FUN.VALUE=numeric(2L), 
               FUN=function(x){
                 w <- knn$type[x,]==1
                 dA <- ifelse(length(wA <- which(w))==0, 2*md,
                              knn$distance[x,wA[1]])
                 dB <- ifelse(length(wB <- which(!w))==0, 2*md,
                              knn$distance[x,wB[1]])
                 c(dA,dB)
               }))
  dw <- sqrt(max(k)-seq_len(max(k))) * 1/knn$distance
  dw <- dw/rowSums(dw)
  d <- data.frame( row.names=row.names(pca), type=ctype, cluster=NA, 
                   weighted=rowSums(knn$type*dw),
                   distanceToNearest=knn$distance[,1],
                   distanceToNearestDoublet=dr[,1],
                   distanceToNearestReal=dr[,2],
                   nearestClass=knn$type[,1],
                   ratio=rowSums(knn$type)/max(k),
                   .getMostLikelyOrigins(knn, origins) )
  if(length(k)>1){
      for(ki in rev(k)[-1])
          d[[paste0("ratio.k",ki)]] <- rowSums(knn$type[,seq_len(ki)])/ki
  }
  
  w <- which(d$type=="doublet")
  class.weighted <- vapply( split(d$weighted[w], d$mostLikelyOrigin[w]), 
                            FUN.VALUE=numeric(1L), FUN=mean )
  
  d$difficulty <- 1
  w <- which(!is.na(d$mostLikelyOrigin))
  d$difficulty[w] <- 1-class.weighted[d$mostLikelyOrigin[w]]
  #d$difficulty <- .knnSmooth(knn, d$difficulty, use.distance=FALSE)
  
  d$expected <- expected[d$mostLikelyOrigin]
  ob <- table(d$mostLikelyOrigin)
  d$observed <- ob[d$mostLikelyOrigin]
  w <- which(is.na(d$mostLikelyOrigin))
  d$observed[w] <- d$expected[w] <- 0
  list(knn=knn, d=d)
}

#' @importFrom stats quantile weighted.mean
.knnSmooth <- function(knn, score, use.distance=TRUE, type=NULL){
  w <- seq_len(ncol(knn$index))
  if(use.distance){
    mind <- quantile(knn$distance[,1], probs=0.1)
    if(mind==0) mind <- 0.5
  }
  vapply(seq_len(nrow(knn$index)), FUN.VALUE=numeric(1L), FUN=function(i){
    x <- knn$index[i,]
    if(!is.null(type)){
      w <- knn$type[i,]==type
    }
    if(sum(w)==0) return(score[i])
    x <- x[w]
    if(use.distance){
      weights <- mind+c(0,knn$distance[i,][w])
      weights <- 1/sqrt(weights)
    }else{
      weights <- 1/seq_len(1+length(x))
    }
    weighted.mean(c(score[i],score[x]),weights)
  })
}

#' @importFrom S4Vectors DataFrame metadata
#' @importFrom stats predict quantile
.scDblscore <- function(d, scoreType="xgb", nrounds=NULL, max_depth=6, iter=2,
                        threshold=TRUE, verbose=TRUE, dbr=NULL, features=NULL,
                        metric="logloss", BPPARAM=SerialParam(), ...){
  gdbr <- dbr
  if(is.null(gdbr)){
    if(is.null(d$sample)){
      sl <- sum(d$src=="real")
    }else{
      ## estimate a global doublet rate
      sl <- as.numeric(table(d$sample, d$src=="real")[,2])
    }
    gdbr <- (0.01*sl/1000)
    gdbr <- sum(gdbr*sl)/sum(sl)
  }
  if(scoreType %in% c("xgb.local.optim","xgb")){
    if(verbose) message("Training model...")
    d$score <- NULL
    if(is.null(features)){
      prds <- setdiff(colnames(d), c("mostLikelyOrigin","originAmbiguous",
                                     "distanceToNearestDoublet", "type",
                                     "src","distanceToNearest","class",
                                     "nearestClass","cluster","sample",
                                     "include.in.training"))
    }else{
      if(length(mis <- setdiff(features, colnames(d)))>0)
        warning("The following features were not found: ", 
                paste(mis,collapse=", "))
      prds <- setdiff(intersect(features, colnames(d)),c("type","src","class"))
    }
    w <- which(d$type=="real")
    d$score <- 0
    d$score[w] <- ecdf(d$ratio[w])(d$ratio[w])
    if(!is.null(d$cxds_score)) d$score[w] <- d$score[w]+
      2*ecdf(d$cxds_score[w])(d$cxds_score[w])
    w <- which(d$type=="real" & d$score >= quantile(d$score[w], 1-gdbr))
    d$include.in.training <- TRUE
    d$include.in.training[w] <- FALSE
    
    while(iter>0){
      # remove cells with a high chance of being doublets from the training
      w <- which(d$type=="real" & 
                   d$score >= quantile(d$score[which(d$type=="real")], 1-gdbr))
      d$score <- tryCatch({
        fit <- .xgbtrain(d[-w,prds], d$type[-w], nrounds, metric=metric,
                         max_depth=ifelse(iter==1,max_depth,5),
                         nthreads=BiocParallel::bpnworkers(BPPARAM))
        predict(fit, as.matrix(d[,prds]))
      }, error=function(e) d$score)
      iter <- iter-1
    }

  }else{
      if(scoreType=="ratio"){
          d$score <- d$ratio
      }else{
          d$score <- d$weighted
      }
  }
  d <- DataFrame(d)
  if(threshold){
      if(verbose) message("Finding threshold...")
      if(!is.null(d$sample) && is.null(dbr) && scoreType!="xgb.local.optim"){
          # per-sample thresholding
          th <- lapply(split(seq_len(nrow(d)), d$sample),
                       FUN=function(x){
                           x <- d[x,c("cluster","src","type","mostLikelyOrigin",
                                  "difficulty","originAmbiguous","score")]
                           dbr <- 0.01*sum(x$src=="real",na.rm=TRUE)/1000
                           doubletThresholding(x, local=FALSE, dbr=dbr, ...)
                       })
          th.stats <- lapply(th, FUN=function(x) x$stats)
          th <- vapply(th, FUN=function(x) x$th, FUN.VALUE=numeric(1))
          d$class <- ifelse(d$score >= th[d$sample], "doublet", "singlet")
          if(verbose) message("Thresholds found:\n", 
                              paste(paste(names(th),round(th,3),sep="="),
                                    collapse=", "))
      }else{
          th <- doubletThresholding( d, local=scoreType=="xgb.local.optim", 
                                     dbr=gdbr, ... )
          if(scoreType=="xgb.local.optim"){
              d$score.global <- d$score
              d$score <- th$finalScores
          }
          th.stats <- th$stats
          th <- th$th
          d$class <- ifelse(d$score >= th, "doublet", "singlet")
          if(verbose) message("Threshold found:", round(th,3))
      }
      ## set class of known (i.e. inputted) doublets:
      d$class[d$src=="real" & d$type=="doublet"] <- "doublet"
      
      metadata(d)$scDblFinder.stats <- th.stats
      metadata(d)$scDblFinder.threshold <- th
      d$nearestClass <- factor(d$nearestClass, levels = 0:1, 
                               labels=c("cell","artificialDoublet"))
      dbr <- sum(d$class=="doublet" & d$src=="real")/sum(d$src=="real")
      if(verbose) message(sum(d$class=="doublet" & d$src=="real"), " (", 
                          round(100*dbr,1),"%) doublets called")
    }
    d
}

#' @import xgboost
.xgbtrain <- function(d2, ctype, nrounds=NULL, max_depth=6, nfold=5, 
                      subsample=0.6, nthreads=1, metric="logloss", ...){
  if(!is.integer(ctype)) ctype <- as.integer(ctype)-1
  d2 <- as.matrix(d2)
  if(is.null(nrounds)){
      # use cross-validation
      res <- xgb.cv(data=d2, label=ctype, nrounds=500, max_depth=max_depth, 
                    objective="binary:logistic", eval_metric=metric,
                    early_stopping_rounds=3, tree_method="hist", nfold=nfold,
                    metrics=list("aucpr","error"), subsample=subsample, 
                    nthread=nthreads, verbose=FALSE, ...)
      ni = res$best_iteration
      ac = res$evaluation_log$test_error_mean[ni] + 
          1 * res$evaluation_log$test_error_std[ni]
      nrounds = min(which(res$evaluation_log$test_error_mean <= ac))
  }
  xgboost( d2, ctype, nrounds=nrounds, eval_metric=metric, 
           objective="binary:logistic", max_depth=max_depth,
           early_stopping_rounds=3, verbose=FALSE, nthread=nthreads,
           ... )
}

# add the relevant fields of the scDblFinder results table to the SCE
#' @importFrom stats relevel
.scDblAddCD <- function(sce, d){
  d <- d[colnames(sce),]
  for(f in c("sample","cluster","class","score","score.global","ratio",
             "weighted","nearestClass","difficulty","cxds_score",
             "mostLikelyOrigin","originAmbiguous")){
    if(!is.null(d[[f]])) sce[[paste0("scDblFinder.",f)]] <- d[[f]]
  }
  if(!is.null(sce$scDblFinder.class)) sce$scDblFinder.class <- 
    relevel(as.factor(sce$scDblFinder.class),"singlet")
  if(is(d,"DataFrame") && !is.null(metadata(d)$scDblFinder.stats))
      metadata(sce)$scDblFinder.stats <- metadata(d)$scDblFinder.stats
  sce
}



.checkSCE <- function(sce){
  if(is(sce, "SummarizedExperiment")){
    sce <- as(sce, "SingleCellExperiment")
  }else if(!is(sce, "SingleCellExperiment")){
    if(is.null(dim(sce)) || any(sce<0))
      stop("`sce` should be a SingleCellExperiment, a SummarizedExperiment, ",
           "or an array (i.e. matrix, sparse matric, etc.) of counts.")
    message("Assuming the input to be a matrix of counts or expected counts.")
    sce <- SingleCellExperiment(list(counts=sce))
  }
  if( !("counts" %in% assayNames(sce)) ) 
      stop("`sce` should have an assay named 'counts'")
  counts(sce) <- as(counts(sce),"dgCMatrix")
  if(is.null(colnames(sce)))
      colnames(sce) <- paste0("cell",seq_len(ncol(sce)))
  if(is.null(row.names(sce)))
      row.names(sce) <- paste0("f",seq_len(nrow(sce)))
  sce
}
