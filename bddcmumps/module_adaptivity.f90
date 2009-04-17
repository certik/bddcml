module module_adaptivity
!***********************
! Module for adaptive search of constraints for BDDC preconditioner
! Jakub Sistek, Denver, 3/2009

! type of reals
integer,parameter,private  :: kr = kind(1.D0)
! numerical zero
real(kr),parameter,private :: numerical_zero = 1.e-12_kr

! debugging 
logical,parameter,private :: debug = .true.

! table of pairs of eigenproblems to compute
! structure:
!  PROC | ISUB | IGLBISUB | JSUB | IGLBJSUB | NVAR
integer,private            :: lpair_subdomains1 
integer,parameter,private  :: lpair_subdomains2 = 6
integer,allocatable,private :: pair_subdomains(:,:)

contains

!*************************************************
subroutine adaptivity_init(myid,comm,idpair,npair)
!*************************************************
! Subroutine for initialization of adaptive search of constraints
      use module_utils
      implicit none
      include "mpif.h"

! number of processor
      integer,intent(in) :: myid
! communicator
      integer,intent(in) :: comm
! file unit with opened list of pairs
      integer,intent(in) :: idpair

! local variables
      integer :: npair
      integer :: ierr
      integer :: ldata

      integer :: ipair, j

! read pairs to be computed data
      if (myid.eq.0) then
         read(idpair,*) npair
      end if
!*****************************************************************MPI
      call MPI_BCAST(npair,1, MPI_INTEGER, 0, comm, ierr)
!*****************************************************************MPI
      lpair_subdomains1 = npair
      allocate(pair_subdomains(lpair_subdomains1,lpair_subdomains2))
      if (myid.eq.0) then
         do ipair = 1,npair
            ! first column is associated with processors - initialize it to -1 = no processor assigned
            pair_subdomains(ipair,1) = -1
            read(idpair,*) (pair_subdomains(ipair,j), j = 2,lpair_subdomains2)
         end do
      end if
      close(idpair)
      ldata = lpair_subdomains1*lpair_subdomains2
!*****************************************************************MPI
      call MPI_BCAST(pair_subdomains,ldata, MPI_INTEGER, 0, comm, ierr)
!*****************************************************************MPI
 
      ! print what is loaded
      if (debug) then
         call adaptivity_print_pairs(myid)
      end if

      return
end subroutine

!*********************************************************
subroutine adaptivity_assign_pairs(npair,nproc,npair_locx)
!*********************************************************
! Subroutine for distribution of load to processors
      implicit none

! Global number of pairs to compute eigenproblems
      integer,intent(in) :: npair
! Number of processors
      integer,intent(in) :: nproc

! local variables
      integer :: iproc, ipair_loc, ipair, npair_locx

      npair_locx = (npair + nproc - 1)/nproc
      ipair = 0
      do iproc = 0,nproc-1
         do ipair_loc = 1,npair_locx
            ipair = ipair + 1
            if (ipair.le.npair) then
               pair_subdomains(ipair,1) = iproc
            end if
         end do
      end do
end subroutine

!******************************************************************************************************************************
subroutine adaptivity_get_active_pairs(iround,nproc,npair,npair_locx,active_pairs,lactive_pairs,nactive_pairs,all_pairs_solved)
!******************************************************************************************************************************
! Subroutine for activating and deactivating pairs
      implicit none

! number of round 
      integer,intent(in) :: iround
! number of pairs
      integer,intent(in) :: npair
! maximal local number of eigenproblems at one processor
      integer,intent(in) :: npair_locx
! number of processors
      integer,intent(in) :: nproc
! indices of active pairs
      integer,intent(in) :: lactive_pairs
      integer,intent(out) :: active_pairs(lactive_pairs)
! number of active pairs
      integer, intent(out) :: nactive_pairs
! set this to true if all pairs are solved
      logical, intent(out) :: all_pairs_solved

! local variables
      integer :: ipair, indpair, iactive_pair, i

      if (iround.gt.npair_locx) then
         all_pairs_solved = .true.
         return
      else
         all_pairs_solved = .false.
      end if

      indpair      = iround
      ipair        = 0
      iactive_pair = 0
      do i = 1,nproc
         ipair = ipair + 1
         if (indpair.le.npair) then
            iactive_pair = iactive_pair + 1
            active_pairs(ipair) = indpair
         else
            active_pairs(ipair) = 0
         end if

         indpair = indpair + npair_locx
      end do
      nactive_pairs = iactive_pair
end subroutine

!**********************************************************************
subroutine adaptivity_get_my_pair(iround,myid,npair_locx,npair,my_pair)
!**********************************************************************
! Subroutine for getting number of pair to solve
      implicit none

! number of round 
      integer,intent(in) :: iround
! processor ID
      integer,intent(in) :: myid
! Maximal local number of eigenproblems at one processor
      integer,intent(in) :: npair_locx
! Global number of pairs to compute eigenproblems
      integer,intent(in) :: npair
! number of pair to solve
      integer,intent(out) :: my_pair 

      my_pair = (myid*npair_locx) + iround
      if (my_pair.gt.npair) then
         my_pair = -1
      end if
end subroutine

!*************************************************************************
subroutine adaptivity_solve_eigenvectors(myid,comm,npair_locx,npair,nproc)
!*************************************************************************
! Subroutine for parallel solution of distributed eigenproblems
      use module_adaptivity_comm
      use module_dd
      use module_utils
      implicit none
      include "mpif.h"

! number of processor
      integer,intent(in) :: myid
! communicator
      integer,intent(in) :: comm

! Maximal local number of eigenproblems at one processor
      integer,intent(in) :: npair_locx

! Global number of pairs to compute eigenproblems
      integer,intent(in) :: npair

! Number of processors
      integer,intent(in) :: nproc

! Maximal number of eigenvectors per problem
      integer,parameter :: neigvecx = 2

! local variables
      integer :: isub, jsub, ipair, iactive_pair, iround, isubgl, jsubgl
      integer :: lvec, my_pair, myisub, myjsub, myisubgl, myjsubgl, mylvec,&
                 myplace1, myplace2, nactive_pairs, ninstructions, owner, &
                 place1, place2, pointbuf, i, j, iinstr, indcorner, icommon, &
                 indc_i, indc_j, indi_i, indi_j, ndofn, nconstr, iconstr, inodi,&
                 pointv_i, pointv_j, shift, indcommon, ndofcomm, idofn, irhoicomm,&
                 point_i, point_j

      integer :: ndofi
      integer :: nnodc
      integer :: nnodi


      integer ::            lpair_data
      integer,allocatable :: pair_data(:)

      ! numbers of active pairs
      integer ::            lactive_pairs
      integer,allocatable :: active_pairs(:)

      logical :: all_pairs_solved

      ! eigenvectors and eigenvalues
      integer ::             leigvec
      real(kr),allocatable :: eigvec(:)
      integer ::             leigval
      real(kr),allocatable :: eigval(:)

      ! corner information
      integer ::            ncommon_corners
      integer ::            lglobal_corner_number_i,   lglobal_corner_number_j
      integer,allocatable :: global_corner_number_i(:), global_corner_number_j(:)
      integer ::            lglobal_corner_number
      integer,allocatable :: global_corner_number(:)
      integer ::            lcommon_corners
      integer,allocatable :: common_corners(:)
      integer ::            licnsin_i,   licnsin_j
      integer,allocatable :: icnsin_i(:), icnsin_j(:)
      integer ::            licnsin
      integer,allocatable :: icnsin(:)
      integer ::            lnndfi_i,   lnndfi_j
      integer,allocatable :: nndfi_i(:), nndfi_j(:)
      integer ::            lnndfi
      integer,allocatable :: nndfi(:)
      integer ::            lkdofi_i,   lkdofi_j
      integer,allocatable :: kdofi_i(:), kdofi_j(:)
      integer ::             lrhoi_i,   lrhoi_j
      real(kr),allocatable :: rhoi_i(:), rhoi_j(:)
      integer ::             lrhoi
      real(kr),allocatable :: rhoi(:)
      integer ::            liingn_i,   liingn_j
      integer,allocatable :: iingn_i(:), iingn_j(:)
      integer ::            liingn
      integer,allocatable :: iingn(:)
      integer ::             lrhoicomm
      real(kr),allocatable :: rhoicomm(:)

      integer ::            ncommon_interface
      integer ::            lcommon_interface
      integer,allocatable :: common_interface(:)

      ! LAPACK QR related variables
      integer :: ldim, lapack_info
      integer ::             lwork
      real(kr),allocatable :: work(:)

      ! LOBPCG related variables
      integer ::  lobpcg_maxit, lobpcg_verbosity
      real(kr) :: lobpcg_tol


      ! allocate table for work instructions - the worst case is that in each
      ! round, I have to compute all the subdomains, i.e. 2 for each pair
      linstructions1 = 2*nproc
      allocate(instructions(linstructions1,linstructions2))
      ! prepare MPI arrays 
      lrequest = 2*nproc + 2
      allocate(request(lrequest))
      lstatarray1 = MPI_STATUS_SIZE
      lstatarray2 = lrequest
      allocate(statarray(lstatarray1,lstatarray2))

      ! loop over number of rounds for solution of eigenproblems
      lactive_pairs = nproc
      allocate(active_pairs(lactive_pairs))

      ! prepare space for pair_data
      lpair_data = lpair_subdomains2
      allocate(pair_data(lpair_data))

      iround = 0
      ! Loop over rounds of eigenvalue solves
      do 
         iround = iround + 1

         ! each round of eigenproblems has its structure - determine active pairs
         call adaptivity_get_active_pairs(iround,nproc,npair,npair_locx,active_pairs,lactive_pairs,nactive_pairs,all_pairs_solved)
         if (all_pairs_solved) then
            exit
         end if

         ! determine which pair I compute
         call adaptivity_get_my_pair(iround,myid,npair_locx,npair,my_pair)

         if (my_pair.ge.0) then

            call adaptivity_get_pair_data(my_pair,pair_data,lpair_data)
   
            myisub     = pair_data(2)
            myisubgl   = pair_data(3)
            myjsub     = pair_data(4)
            myjsubgl   = pair_data(5)
            mylvec     = pair_data(6)

            ! where are these subdomains ?
            call dd_where_is_subdomain(myisub,myplace1)
            call dd_where_is_subdomain(myjsub,myplace2)
         end if


         ! determine working instructions for sending subdomain matrices
         ! go through pairs that are active in this round
         instructions  = 0
         ninstructions = 0
         pointbuf      = 1
         do ipair = 1,nactive_pairs
            iactive_pair = active_pairs(ipair)
            
            call adaptivity_get_pair_data(iactive_pair,pair_data,lpair_data)
            owner  = pair_data(1)
            isub   = pair_data(2)
            isubgl = pair_data(3)
            jsub   = pair_data(4)
            jsubgl = pair_data(5)
            lvec   = pair_data(6)

            ! where are these subdomains ?
            call dd_where_is_subdomain(isub,place1)
            call dd_where_is_subdomain(jsub,place2)

            if (myid.eq.place1) then
               ! add instruction
               ninstructions = ninstructions + 1

               ! who I will send data to
               instructions(ninstructions,1) = owner
               ! subdomain number
               instructions(ninstructions,2) = isub
               ! glob number
               instructions(ninstructions,3) = isubgl
            end if

            if (myid.eq.place2) then
               ! add instruction
               ninstructions = ninstructions + 1

               ! who I will send data to
               instructions(ninstructions,1) = owner
               ! subdomain number
               instructions(ninstructions,2) = jsub
               ! glob number
               instructions(ninstructions,3) = jsubgl
            end if
         end do

         ! the scheme for communication is ready
         print *, 'myid =',myid, 'pair_data:'
         print *, pair_data
         print *, 'myid =',myid, 'instructions:'
         do i = 1,ninstructions
            print *, instructions(i,:)
         end do

         ! build the local matrix of projection on common globs for active pair
         !  get sizes of interface of subdomains in my problem
         ireq = 0
         if (my_pair.ge.0) then
            ! receive sizes of interfaces of subdomains involved in my problem

            ireq = ireq + 1
            call MPI_IRECV(ndofi_i,1,MPI_INTEGER,myplace1,myisub,comm,request(ireq),ierr)

            ireq = ireq + 1
            call MPI_IRECV(ndofi_j,1,MPI_INTEGER,myplace2,myjsub,comm,request(ireq),ierr)
         end if
         ! send sizes of subdomains involved in problems
         do iinstr = 1,ninstructions
            owner = instructions(iinstr,1)
            isub  = instructions(iinstr,2)
            call dd_get_interface_size(myid,isub,ndofi,nnodi)

            ireq = ireq + 1
            call MPI_ISEND(ndofi,1,MPI_INTEGER,owner,isub,comm,request(ireq),ierr)
         end do
         nreq = ireq
         if (nreq.gt.size(request)) then
            write(*,*) 'ADAPTIVITY_SOLVE_EIGENVECTORS: Not enough space for MPI requests.'
            call error_exit
         end if
         call MPI_WAITALL(nreq, request, statarray, ierr)
         print *, 'All messages in pack 1 received, MPI is fun!.'

         if (my_pair.ge.0) then
            print *, 'ndofi_i',ndofi_i,'ndofi_j',ndofi_j
         end if

         !  get number of corners to find common subset
         ireq = 0
         if (my_pair.ge.0) then
            ! receive numbers of corners

            ireq = ireq + 1
            call MPI_IRECV(nnodci,1,MPI_INTEGER,myplace1,myisub,comm,request(ireq),ierr)

            ireq = ireq + 1
            call MPI_IRECV(nnodcj,1,MPI_INTEGER,myplace2,myjsub,comm,request(ireq),ierr)
         end if
         ! send sizes of subdomains involved in problems
         do iinstr = 1,ninstructions
            owner = instructions(iinstr,1)
            isub  = instructions(iinstr,2)
            call dd_get_number_of_corners(myid,isub,nnodc)

            ireq = ireq + 1
            call MPI_ISEND(nnodc,1,MPI_INTEGER,owner,isub,comm,request(ireq),ierr)
         end do
         nreq = ireq
         call MPI_WAITALL(nreq, request, statarray, ierr)
         print *, 'All messages in pack 2 received, MPI is fun!.'

         if (my_pair.ge.0) then
            print *, 'nnodci',nnodci,'nnodcj',nnodcj
         end if

         !  get number of nodes on interface
         ireq = 0
         if (my_pair.ge.0) then
            ! receive numbers of corners

            ireq = ireq + 1
            call MPI_IRECV(nnodi_i,1,MPI_INTEGER,myplace1,myisub,comm,request(ireq),ierr)

            ireq = ireq + 1
            call MPI_IRECV(nnodi_j,1,MPI_INTEGER,myplace2,myjsub,comm,request(ireq),ierr)
         end if
         ! send sizes of subdomains involved in problems
         do iinstr = 1,ninstructions
            owner = instructions(iinstr,1)
            isub  = instructions(iinstr,2)
            call dd_get_interface_size(myid,isub,ndofi,nnodi)

            ireq = ireq + 1
            call MPI_ISEND(nnodi,1,MPI_INTEGER,owner,isub,comm,request(ireq),ierr)
         end do
         nreq = ireq
         call MPI_WAITALL(nreq, request, statarray, ierr)
         print *, 'All messages in pack 2.5 received, MPI is fun!.'
         if (my_pair.ge.0) then
            print *, 'nnodi_i',nnodi_i,'nnodi_j',nnodi_j
         end if

         ! allocate space for corners
         if (my_pair.ge.0) then
            lglobal_corner_number_i = nnodci
            lglobal_corner_number_j = nnodcj
            allocate(global_corner_number_i(lglobal_corner_number_i),global_corner_number_j(lglobal_corner_number_j))
            licnsin_i = nnodci
            licnsin_j = nnodcj
            allocate(icnsin_i(licnsin_i),icnsin_j(licnsin_j))
            lnndfi_i = nnodi_i
            lnndfi_j = nnodi_j
            allocate(nndfi_i(lnndfi_i),nndfi_j(lnndfi_j))
            lrhoi_i = ndofi_i
            lrhoi_j = ndofi_j
            allocate(rhoi_i(lrhoi_i),rhoi_j(lrhoi_j))
            liingn_i = nnodi_i
            liingn_j = nnodi_j
            allocate(iingn_i(liingn_i),iingn_j(liingn_j))
         end if
         ! get data about corners
         ireq = 0
         if (my_pair.ge.0) then
            ! receive global numbers of corners

            ireq = ireq + 1
            call MPI_IRECV(global_corner_number_i,nnodci,MPI_INTEGER,myplace1,myisub,comm,request(ireq),ierr)

            ireq = ireq + 1
            call MPI_IRECV(global_corner_number_j,nnodcj,MPI_INTEGER,myplace2,myjsub,comm,request(ireq),ierr)
         end if
         ! send sizes of subdomains involved in problems
         do iinstr = 1,ninstructions
            owner = instructions(iinstr,1)
            isub  = instructions(iinstr,2)
            call dd_get_number_of_corners(myid,isub,nnodc)

            lglobal_corner_number = nnodc
            allocate(global_corner_number(lglobal_corner_number))
            call dd_get_subdomain_corners(myid,isub,global_corner_number,lglobal_corner_number)

            ireq = ireq + 1
            call MPI_ISEND(global_corner_number,nnodc,MPI_INTEGER,owner,isub,comm,request(ireq),ierr)
            deallocate(global_corner_number)
         end do
         nreq = ireq
         call MPI_WAITALL(nreq, request, statarray, ierr)
         print *, 'All messages in pack 3 received, MPI is fun!.'
         if (my_pair.ge.0) then
            print *, 'global_corner_number_i'
            print *,  global_corner_number_i
            print *, 'global_corner_number_j'
            print *,  global_corner_number_j
         end if
         ! get data about corners
         ireq = 0
         if (my_pair.ge.0) then
            ! receive global numbers of corners

            ireq = ireq + 1
            call MPI_IRECV(icnsin_i,nnodci,MPI_INTEGER,myplace1,myisub,comm,request(ireq),ierr)

            ireq = ireq + 1
            call MPI_IRECV(icnsin_j,nnodcj,MPI_INTEGER,myplace2,myjsub,comm,request(ireq),ierr)
         end if
         ! send sizes of subdomains involved in problems
         do iinstr = 1,ninstructions
            owner = instructions(iinstr,1)
            isub  = instructions(iinstr,2)
            call dd_get_number_of_corners(myid,isub,nnodc)

            licnsin = nnodc
            allocate(icnsin(licnsin))
            call dd_get_subdomain_corners_map(myid,isub,icnsin,licnsin)

            ireq = ireq + 1
            call MPI_ISEND(icnsin,nnodc,MPI_INTEGER,owner,isub,comm,request(ireq),ierr)
            deallocate(icnsin)
         end do
         nreq = ireq
         call MPI_WAITALL(nreq, request, statarray, ierr)
         print *, 'All messages in pack 4 received, MPI is fun!.'

         ! get numbers of dof on interface
         ireq = 0
         if (my_pair.ge.0) then
            ! receive global numbers of corners

            ireq = ireq + 1
            call MPI_IRECV(nndfi_i,nnodi_i,MPI_INTEGER,myplace1,myisub,comm,request(ireq),ierr)

            ireq = ireq + 1
            call MPI_IRECV(nndfi_j,nnodi_j,MPI_INTEGER,myplace2,myjsub,comm,request(ireq),ierr)
         end if
         ! send sizes of subdomains involved in problems
         do iinstr = 1,ninstructions
            owner = instructions(iinstr,1)
            isub  = instructions(iinstr,2)
            call dd_get_interface_size(myid,isub,ndofi,nnodi)

            lnndfi = nnodi
            allocate(nndfi(lnndfi))
            call dd_get_subdomain_interface_nndf(myid,isub,nndfi,lnndfi)

            ireq = ireq + 1
            call MPI_ISEND(nndfi,nnodi,MPI_INTEGER,owner,isub,comm,request(ireq),ierr)
            deallocate(nndfi)
         end do
         nreq = ireq
         call MPI_WAITALL(nreq, request, statarray, ierr)
         print *, 'All messages in pack 5 received, MPI is fun!.'
         if (my_pair.ge.0) then
            print *, 'nndfi_i'
            print *,  nndfi_i
            print *, 'nndfi_j'
            print *,  nndfi_j
         end if

         ! find intersection of corners
         lcommon_corners = min(lglobal_corner_number_i,lglobal_corner_number_j)
         allocate(common_corners(lcommon_corners))
         if (my_pair.ge.0) then
            call get_array_intersection(global_corner_number_i,lglobal_corner_number_i,&
                                        global_corner_number_j,lglobal_corner_number_j,&
                                        common_corners,lcommon_corners,ncommon_corners)
         end if

         ! build matrix D_ij^T for the pair of subdomains
         if (my_pair.ge.0) then
            ! first determine the size of D_ij
            nconstr = 0
            do icommon = 1,ncommon_corners
               indcorner = common_corners(icommon)
               ! find index of this corner
               call get_index(indcorner,global_corner_number_i,lglobal_corner_number_i,indc_i) 
               indi_i = icnsin_i(indc_i)
               ndofn  = nndfi_i(indi_i)

               nconstr = nconstr + ndofn
            end do
            ! prepare space for dense matrix D_ij
            ldij1 = ndofi_i + ndofi_j
            ldij2 = nconstr
            allocate(dij(ldij1,ldij2))

            ! prepare arrays kdofi_i and kdofi_j
            lkdofi_i = nnodi_i
            lkdofi_j = nnodi_j
            allocate(kdofi_i(lkdofi_i),kdofi_j(lkdofi_j))
            kdofi_i(1) = 0
            do inodi = 2,nnodi_i
               kdofi_i(inodi) = kdofi_i(inodi-1) + nndfi_i(inodi-1)
            end do
            kdofi_j(1) = 0
            do inodi = 2,nnodi_j
               kdofi_j(inodi) = kdofi_j(inodi-1) + nndfi_j(inodi-1)
            end do

            iconstr = 0
            do icommon = 1,ncommon_corners
               indcorner = common_corners(icommon)
               ! find index of this corner
               call get_index(indcorner,global_corner_number_i,lglobal_corner_number_i,indc_i) 
               indi_i = icnsin_i(indc_i)
               ndofn  = nndfi_i(indi_i)
               call get_index(indcorner,global_corner_number_i,lglobal_corner_number_i,indc_j) 
               indi_j = icnsin_j(indc_j)

               shift = ndofi_i
               pointv_i = kdofi_i(indi_i)
               pointv_j = kdofi_j(indi_j)
               do i = 1,ndofn
                  iconstr = iconstr + 1

                  ! contribution of subdomain i
                  dij(pointv_i+i,iconstr)       = 1._kr
                  ! contribution of subdomain j
                  dij(shift+pointv_j+i,iconstr) = -1._kr
               end do
            end do
         end if

         if (my_pair.ge.0) then
            do i = 1,ldij1
               print *,(dij(i,j),j = 1,ldij2)
            end do
         end if

         ! Prepare projection onto null D_ij
         if (my_pair.ge.0) then
            ! QR decomposition of matrix Dij^T
            ! LAPACK arrays
            ltau = ldij2
            allocate(tau(ltau))
            lwork = ldij2
            allocate(work(lwork))
            ! leading dimension
            ldim = max(1,ldij1)
            call DGEQR2( ldij1, ldij2, dij, ldim, tau, work, lapack_info)
            if (lapack_info.ne.0) then
               write(*,*) 'ADAPTIVITY_SOLVE_EIGENVECTORS: Error in LAPACK QR factorization of matrix D_ij^T: ', lapack_info
               call error_exit
            end if
            deallocate(work)
            ! in space of D_ij are now stored factors R and Householder reflectors v
         end if

         if (my_pair.ge.0) then
            print *,'Factors of D_ij^T after QR'
            do i = 1,ldij1
               print *,(dij(i,j),j = 1,ldij2)
            end do
         end if


         ! prepare operator (I-R_ijE_ij)
         ! get data about interface weigths
         ireq = 0
         if (my_pair.ge.0) then
            ! receive diagonal entries

            ireq = ireq + 1
            call MPI_IRECV(rhoi_i,ndofi_i,MPI_DOUBLE_PRECISION,myplace1,myisub,comm,request(ireq),ierr)

            ireq = ireq + 1
            call MPI_IRECV(rhoi_j,ndofi_j,MPI_DOUBLE_PRECISION,myplace2,myjsub,comm,request(ireq),ierr)
         end if
         do iinstr = 1,ninstructions
            owner = instructions(iinstr,1)
            isub  = instructions(iinstr,2)
            call dd_get_interface_size(myid,isub,ndofi,nnodi)

            lrhoi = ndofi
            allocate(rhoi(lrhoi))
            call dd_get_interface_diagonal(myid,isub, rhoi,lrhoi)

            ireq = ireq + 1
            call MPI_ISEND(rhoi,ndofi,MPI_DOUBLE_PRECISION,owner,isub,comm,request(ireq),ierr)
            deallocate(rhoi)
         end do
         nreq = ireq
         call MPI_WAITALL(nreq, request, statarray, ierr)
         print *, 'All messages in pack 7 received, MPI is fun!.'
         if (my_pair.ge.0) then
            print *, 'rhoi_i'
            print *,  rhoi_i
            print *, 'rhoi_j'
            print *,  rhoi_j
         end if

         ! get data about common interface
         ireq = 0
         if (my_pair.ge.0) then
            ! receive mapping of interface nodes into global nodes

            ireq = ireq + 1
            call MPI_IRECV(iingn_i,nnodi_i,MPI_INTEGER,myplace1,myisub,comm,request(ireq),ierr)

            ireq = ireq + 1
            call MPI_IRECV(iingn_j,nnodi_j,MPI_INTEGER,myplace2,myjsub,comm,request(ireq),ierr)
         end if
         ! send sizes of subdomains involved in problems
         do iinstr = 1,ninstructions
            owner = instructions(iinstr,1)
            isub  = instructions(iinstr,2)
            call dd_get_interface_size(myid,isub,ndofi,nnodi)

            liingn = nnodi
            allocate(iingn(liingn))
            call dd_get_interface_global_numbers(myid,isub,iingn,liingn)

            ireq = ireq + 1
            call MPI_ISEND(iingn,nnodi,MPI_INTEGER,owner,isub,comm,request(ireq),ierr)
            deallocate(iingn)
         end do
         nreq = ireq
         call MPI_WAITALL(nreq, request, statarray, ierr)
         print *, 'All messages in pack 8 received, MPI is fun!.'
         if (my_pair.ge.0) then
            print *, 'iingn_i'
            print *,  iingn_i
            print *, 'iingn_j'
            print *,  iingn_j
         end if

         ! find common intersection of interface nodes
         if (my_pair.ge.0) then
            lcommon_interface = min(nnodi_i,nnodi_j)
            allocate(common_interface(lcommon_interface))
            if (my_pair.ge.0) then
               call get_array_intersection(iingn_i,liingn_i, iingn_j,liingn_j,&
                                           common_interface,lcommon_interface,ncommon_interface)
            end if
            ! determine size of common interface
            ndofcomm = 0
            do icommon = 1,ncommon_interface
               indcommon = common_interface(icommon)
               call get_index(indcommon,iingn_i,liingn_i,indi_i)
               ndofn = nndfi_i(indi_i)

               ndofcomm = ndofcomm + ndofn
            end do
            ! prepare space for sum of interface entries
            lrhoicomm = ndofcomm
            allocate(rhoicomm(lrhoicomm))
            irhoicomm = 0
            ! sum diagonal entries on interface
            do icommon = 1,ncommon_interface
               indcommon = common_interface(icommon)
               call get_index(indcommon,iingn_i,liingn_i,indi_i)
               point_i = kdofi_i(indi_i)
               call get_index(indcommon,iingn_j,liingn_j,indi_j)
               point_j = kdofi_j(indi_j)

               ndofn = nndfi_i(indi_i)

               do idofn = 1,ndofn
                  irhoicomm = irhoicomm + 1

                  rhoicomm(irhoicomm) = rhoi_i(point_i + idofn) + rhoi_j(point_j + idofn)
               end do
            end do
            ! prepare vector of mask and weigths representing (I - R_ij E_ij)
            limre = ndofi_i + ndofi_j
            allocate(imre(limre))
            call zero(imre,limre)
            irhoicomm = 0
            shift = ndofi_i
            do icommon = 1,ncommon_interface
               indcommon = common_interface(icommon)
               call get_index(indcommon,iingn_i,liingn_i,indi_i)
               point_i = kdofi_i(indi_i)
               call get_index(indcommon,iingn_j,liingn_j,indi_j)
               point_j = kdofi_j(indi_j)

               ndofn = nndfi_i(indi_i)

               do idofn = 1,ndofn
                  irhoicomm = irhoicomm + 1

                  imre(        point_i + idofn) = rhoi_i(point_i + idofn) / rhoicomm(irhoicomm)
                  imre(shift + point_j + idofn) = rhoi_j(point_j + idofn) / rhoicomm(irhoicomm)
               end do
            end do

            deallocate(rhoicomm)
            print *, 'imre',imre
         end if


         ! prepare space for eigenvectors
         ireq = 0
         if (my_pair.ge.0) then
            neigvec     = min(neigvecx,mylvec)
            problemsize = ndofi_i + ndofi_j
            leigvec = neigvec * problemsize
            leigval = neigvec
            allocate(eigvec(leigvec),eigval(leigval))

            ! prepare space for buffers
            lbufsend_i = ndofi_i * neigvec
            lbufsend_j = ndofi_j * neigvec
            allocate(bufsend_i(lbufsend_i),bufsend_j(lbufsend_j))

            ! distribute sizes of chunks of eigenvectors
            ireq = ireq + 1
            call MPI_ISEND(lbufsend_i,1,MPI_INTEGER,myplace1,myisub,comm,request(ireq),ierr)

            ireq = ireq + 1
            call MPI_ISEND(lbufsend_j,1,MPI_INTEGER,myplace2,myjsub,comm,request(ireq),ierr)
         end if
         ! prepare pointers to buffers with chunks of eigenvectors and their size
         llbufa = ninstructions
         allocate(lbufa(llbufa))
         do iinstr = 1,ninstructions
            owner = instructions(iinstr,1)
            isub  = instructions(iinstr,2)

            ireq = ireq + 1
            call MPI_IRECV(lbufa(iinstr),1,MPI_INTEGER,owner,isub,comm,request(ireq),ierr)
         end do
         nreq = ireq
         call MPI_WAITALL(nreq, request, statarray, ierr)
         ! prepare arrays kbufsend and 
         lkbufsend = ninstructions
         allocate(kbufsend(lkbufsend))
         kbufsend(1)  = 1
         do i = 2,ninstructions
            kbufsend(i) = kbufsend(i-1) + lbufa(i-1)
         end do
         print *, 'All messages in pack 9 received, MPI is fun!.'
         print *, 'myid',myid,'lbufa'
         print *,  lbufa
         print *, 'myid',myid,'kbufsend'
         print *,  kbufsend
         lbufsend = 0
         do i = 1,ninstructions
            lbufsend = lbufsend + lbufa(i)
         end do
         allocate(bufsend(lbufsend))

         ! All arrays are ready for iterational process
         ! call LOBCPG
         comm_comm = comm
         if (my_pair.ge.0) then
            lobpcg_tol   = 1.e-6_kr
            lobpcg_maxit = 1000
            problemsize = ndofi_i + ndofi_j
            lobpcg_verbosity = 0
            if (debug) then
               write(*,*) 'myid =',myid,', I am calling eigensolver for pair ',my_pair
            end if
            call lobpcg_driver(problemsize,neigvec,lobpcg_tol,lobpcg_maxit,lobpcg_verbosity,eigval,eigvec)
            ! turn around the eigenvalues to be the largest
            eigval = -eigval
            print *, 'eigval ='
            print '(f13.7)', eigval
            print *, 'x ='
            do i = 1,problemsize
               print '(30f13.7)', (eigvec((j-1)*problemsize + i),j = 1,neigvec)
            end do
         end if
         call adaptivity_fake_lobpcg_driver


         deallocate(bufsend)
         deallocate(lbufa)
         deallocate(kbufsend) 
         if (my_pair.ge.0) then
            deallocate(eigvec,eigval)
            deallocate(bufsend_i,bufsend_j)
            deallocate(imre)
            deallocate(common_interface)
            deallocate(iingn_i,iingn_j)
            deallocate(rhoi_i,rhoi_j)
            deallocate(tau)
            deallocate(kdofi_i,kdofi_j)
            deallocate(dij)
            deallocate(common_corners)
            deallocate(nndfi_i,nndfi_j)
            deallocate(icnsin_i,icnsin_j)
            deallocate(global_corner_number_i,global_corner_number_j)
         end if
      end do

      deallocate(statarray)
      deallocate(request)
      deallocate(pair_data)
      deallocate(active_pairs)
      deallocate(instructions)

end subroutine

!***************************************
subroutine adaptivity_fake_lobpcg_driver
!***************************************
! Subroutine for looping to compute all Schur complement multiplications in eigenproblems
      implicit none

! local variables
      integer :: idmatrix

      ! these have no meaning and are present only for matching the arguments
      integer :: n, lx = 0, ly = 0
      real(kr) :: x , y


      ! repeat loop until idmat not equal 3
      ! here the only important argument is idmatrix
      ! all other necessary data are obtained through modules
      idmatrix = 3
      do 
         call lobpcg_mvecmult_f(n,x,lx,y,ly,idmatrix)
         ! stopping criterion
         if (idmatrix .ne. 3) then
            exit
         end if
      end do

end subroutine

!***************************************************************
subroutine adaptivity_get_pair_data(idpair,pair_data,lpair_data)
!***************************************************************
! Subroutine for getting info about pairs to the global structure
      use module_utils
      implicit none

! pair number
      integer,intent(in) :: idpair
! length of vector for data
      integer,intent(in) :: lpair_data
! vector of data for pair IDPAIR
      integer,intent(out) :: pair_data(lpair_data)

! local variables
      integer :: i

      ! check the length of vector for data
      if (lpair_data .ne. lpair_subdomains2) then
         write(*,*) 'ADAPTIVITY_GET_PAIR_DATA: Size not sufficient for getting info about pair.'
         call error_exit
      end if
      ! check that the info about pair is available
      if (.not.allocated(pair_subdomains)) then
         write(*,*) 'ADAPTIVITY_GET_PAIR_DATA: Structure with global pair data is not allocated.'
         call error_exit
      end if
      if (pair_subdomains(idpair,1).eq.-1) then
         write(*,*) 'ADAPTIVITY_GET_PAIR_DATA: Incomplete information about pair - processor not assigned.'
         call error_exit
      end if
      if (any(pair_subdomains(idpair,2:).eq.0)) then
         write(*,*) 'ADAPTIVITY_GET_PAIR_DATA: Incomplete information about pair - zeros in subdomain data.'
         call error_exit
      end if

      ! after checking, get info about pair from the global structure and load it
      do i = 1,lpair_data
         pair_data(i) = pair_subdomains(idpair,i)
      end do

end subroutine


!**************************************
subroutine adaptivity_print_pairs(myid)
!**************************************
! Subroutine for printing data about pairs to screen
      implicit none

! number of processor
      integer,intent(in) :: myid

! local variables
      integer :: ipair, j

      write(*,*) 'Info about loaded pairs on processor ',myid,',',lpair_subdomains1,' pairs loaded:'
      if (allocated(pair_subdomains)) then
         do ipair = 1,lpair_subdomains1
            write(*,'(6i10)') (pair_subdomains(ipair,j),j = 1,lpair_subdomains2)
         end do
      else 
         write(*,*) 'ADAPTIVITY_PRINT_PAIRS: Array of pairs is not allocated.'
      end if
end subroutine

!*****************************
subroutine adaptivity_finalize
!*****************************
! Subroutine for finalization of adaptivity
      implicit none

! clear memory
      if (allocated(pair_subdomains)) then
         deallocate(pair_subdomains)
      end if

      return
end subroutine

end module module_adaptivity


