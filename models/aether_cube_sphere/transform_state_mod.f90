module transform_state_mod

use netcdf
use types_mod,            only : r4, r8, varnamelength
use netcdf_utilities_mod, only : nc_open_file_readonly, nc_open_file_readwrite, nc_close_file, &
                                 nc_create_file, nc_end_define_mode
use utilities_mod,        only : open_file, close_file, find_namelist_in_file, &
                                 check_namelist_read, error_handler, E_ERR, string_to_integer

implicit none
private

public :: initialize_transform_state_mod, &
          finalize_transform_state_mod, &
          model_to_dart, &
          dart_to_model, &
          integer_to_string, &
          file_type, &
          zero_fill

integer  :: iunit, io

character(len=4) :: restart_ensemble_member, dart_ensemble_member

type :: file_type
character(len=256) :: file_path
integer :: ncid, ncstatus, unlimitedDimId, nDimensions, nVariables, nAttributes, formatNum
end type file_type

type(file_type), allocatable, dimension(:) :: block_files
type(file_type) :: filter_input_file, filter_output_file

integer :: nblocks, nhalos
character(len=256) :: restart_file_prefix, restart_file_middle, restart_file_suffix, &
                      filter_input_prefix, filter_input_suffix, filter_output_prefix, &
                      filter_output_suffix
namelist /transform_state_nml/ nblocks, nhalos, restart_file_prefix, restart_file_middle, &
                               restart_file_suffix, filter_input_prefix, filter_input_suffix, &
                               filter_output_prefix, filter_output_suffix

character(len=256) :: restart_directory, grid_directory, filter_directory
namelist /directory_nml/ restart_directory, grid_directory, filter_directory

contains

subroutine initialize_transform_state_mod()

   restart_ensemble_member = get_ensemble_member_from_command_line()
   dart_ensemble_member = zero_fill(integer_to_string(string_to_integer(restart_ensemble_member)+1), 4)

   call find_namelist_in_file('input.nml', 'transform_state_nml', iunit)
   read(iunit, nml = transform_state_nml, iostat = io)
   call check_namelist_read(iunit, io, 'transform_state_nml')

   call find_namelist_in_file('input.nml', 'directory_nml', iunit)
   read(iunit, nml = directory_nml, iostat = io)
   call check_namelist_read(iunit, io, 'directory_nml')

   block_files = assign_block_files_array(nblocks, restart_ensemble_member, restart_directory, &
                                          restart_file_prefix, restart_file_middle, &
                                          restart_file_suffix)

   

end subroutine initialize_transform_state_mod

subroutine finalize_transform_state_mod()
   
   integer :: iblock

   ! Close all of the files

   do iblock = 1, nblocks
      call nc_close_file(block_files(iblock)%ncid)
   end do

end subroutine finalize_transform_state_mod

subroutine model_to_dart()

   integer :: iblock
   integer :: dimid, dart_dimid
   integer :: ix, iy, iz, icol
   integer :: varid
   character(len=NF90_MAX_NAME) :: name
   character(len=NF90_MAX_NAME) :: attribute
   integer :: length
   integer :: xtype, nDimensions, nAtts
   integer, dimension(NF90_MAX_VAR_DIMS) :: dimids
   integer :: ntimes
   integer :: nxs_per_block, nys_per_block, truncated_nxs_per_block, truncated_nys_per_block, total_truncated_ncols
   integer :: nzs

   integer, dimension(3) :: time_lev_col_dims
   integer, allocatable, dimension (:) :: dart_varids

   ! The time variable in the block files is a double
   real(r8), allocatable, dimension(:) :: time_array
   ! The other variables are floats
   real(r4), allocatable, dimension(:, :, :) :: block_array
   real(r4), allocatable, dimension(:) :: spatial_array
   real(r4), allocatable, dimension(:, :, :) :: variable_array

   filter_input_file = assign_filter_file(dart_ensemble_member, filter_directory, filter_input_prefix, filter_input_suffix)

   ! The block files are read only
   do iblock = 1, nblocks
      block_files(iblock)%ncid = nc_open_file_readonly(block_files(iblock)%file_path)
   end do

   ! The dart file is create
   filter_input_file%ncid = nc_create_file(filter_input_file%file_path)

   ! The first set of nested loops iterates through all of the block files and all of the dimensions
   ! of each block file and counts the lengths of each dimension.

   do iblock = 1, nblocks
      ! There doesn't seem to be a helper procedure corresponding to nf90_inquire in
      ! netcdf_utilities_mod so this uses the external function directly from the netcdf library
      block_files(iblock)%ncstatus = nf90_inquire(block_files(iblock)%ncid, &
                                                  block_files(iblock)%nDimensions, &
                                                  block_files(iblock)%nVariables, &
                                                  block_files(iblock)%nAttributes, &
                                                  block_files(iblock)%unlimitedDimId, &
                                                  block_files(iblock)%formatNum)
      
      if (iblock == 1) then
         do dimid = 1, block_files(iblock)%nDimensions
            ! There doesn't seem to be a helper procedure corresponding to nf90_inquire_dimension that
            ! assigns name and length in netcdf_utilities_mod so this uses the external function
            ! directly from the netcdf library
            block_files(iblock)%ncstatus = nf90_inquire_dimension(block_files(iblock)%ncid, dimid, name, length)

            if (trim(name) == 'time') then
               ntimes = length
            else if (trim(name) == 'x') then
               truncated_nxs_per_block = length-2*nhalos
               nxs_per_block = length
            else if (trim(name) == 'y') then
               truncated_nys_per_block = length-2*nhalos
               nys_per_block = length
            else if (trim(name) == 'z') then
               nzs = length
            end if
         end do
      end if
   end do

   total_truncated_ncols = truncated_nxs_per_block*truncated_nys_per_block*nblocks

   ! All of the lengths have been counted properly, create each dimension in the filter_input_file and save
   ! the dimensions to the time_x_y_z and x_y_z arrays used during variable definition
   filter_input_file%ncstatus = nf90_def_dim(filter_input_file%ncid, 'time', NF90_UNLIMITED, dart_dimid)
   time_lev_col_dims(3) = dart_dimid

   filter_input_file%ncstatus = nf90_def_dim(filter_input_file%ncid, 'z', nzs, dart_dimid)
   time_lev_col_dims(2) = dart_dimid

   filter_input_file%ncstatus = nf90_def_dim(filter_input_file%ncid, 'col', total_truncated_ncols, dart_dimid)
   time_lev_col_dims(1) = dart_dimid

   ! Allocate all of the storage arrays
   allocate(time_array(ntimes))
   allocate(block_array(nzs, nys_per_block, nxs_per_block))
   allocate(spatial_array(total_truncated_ncols))
   allocate(variable_array(total_truncated_ncols, nzs, ntimes))
   allocate(dart_varids(block_files(1)%nVariables))

   block_array(:, :, :) = 0
   spatial_array(:) = 0
   variable_array(:, :, :) = 0

   ! The filter_input_file is still in define mode. Create all of the variables before entering data mode.
   do varid = 1, block_files(1)%nVariables
      block_files(1)%ncstatus = nf90_inquire_variable(block_files(1)%ncid, varid, name, xtype, nDimensions, dimids, nAtts)
      if (trim(name) == 'time') then
         filter_input_file%ncstatus = nf90_def_var(filter_input_file%ncid, name, xtype, time_lev_col_dims(3), dart_varids(varid))
      else if (trim(name) == 'z') then
         ! Rename the 'z' variable as 'alt' so there isn't a dimension and a variable with the same name
         filter_input_file%ncstatus = nf90_def_var(filter_input_file%ncid, 'alt', xtype, time_lev_col_dims(2), dart_varids(varid))
      else if ((trim(name) == 'lon') .or. (trim(name) == 'lat')) then
         filter_input_file%ncstatus = nf90_def_var(filter_input_file%ncid, name, xtype, time_lev_col_dims(1), dart_varids(varid))
      else
         filter_input_file%ncstatus = nf90_def_var(filter_input_file%ncid, name, xtype, time_lev_col_dims, dart_varids(varid))
      end if

      ! In the block files, time does not have units
      if (trim(name) /= 'time') then
         block_files(iblock)%ncstatus = nf90_get_att(block_files(1)%ncid, varid, 'units', attribute)
         filter_input_file%ncstatus = nf90_put_att(filter_input_file%ncid, dart_varids(varid), 'units', attribute)
      end if

      ! In the block files, only lon, lat and z have long_name
      if ((trim(name) == 'lon') .or. (trim(name) == 'lat') .or. (trim(name) == 'z')) then
         block_files(iblock)%ncstatus = nf90_get_att(block_files(1)%ncid, varid, 'long_name', attribute)
         filter_input_file%ncstatus = nf90_put_att(filter_input_file%ncid, dart_varids(varid), 'long_name', attribute)
      end if

      ! print *, 'name: ' // name
      ! print *, 'dart_varids(varid): ' // integer_to_string(dart_varids(varid))

   end do

   call nc_end_define_mode(filter_input_file%ncid)

   ! The second set of nested loops has a different loop order. The outer loop is all of the
   ! variables while the inner loop is all of the blocks. The order is switched because all of the
   ! ncid pointers to each of the block files have already been assigned and it is more
   ! straightforward to assign all of the elements in the variable arrays if the blocks are the
   ! inner loop.

   do varid = 1, block_files(1)%nVariables
      icol = 0
      do iblock = 1, nblocks
         block_files(iblock)%ncstatus = nf90_inquire_variable(block_files(iblock)%ncid, varid, name, xtype, nDimensions, dimids, nAtts)
         
         if (trim(name) == 'time') then
            ! This is a 1-D time array
            if (iblock == 1) then
               block_files(iblock)%ncstatus = nf90_get_var(block_files(iblock)%ncid, varid, time_array)
               filter_input_file%ncstatus = nf90_put_var(filter_input_file%ncid, dart_varids(varid), time_array)
            end if
         else if (trim(name) == 'z') then
            if (iblock == 1) then
               block_files(iblock)%ncstatus = nf90_get_var(block_files(iblock)%ncid, varid, block_array)
               filter_input_file%ncstatus = nf90_put_var(filter_input_file%ncid, dart_varids(varid), block_array(:,1,1))
            end if
         else
            ! All of the variables besides time can be read into the block array
            block_files(iblock)%ncstatus = nf90_get_var(block_files(iblock)%ncid, varid, block_array)
            
            if ((trim(name) == 'lon') .or. (trim(name) == 'lat')) then
               do iy = 1, truncated_nys_per_block
                  do ix = 1, truncated_nxs_per_block
                     icol = icol + 1
                     spatial_array(icol) = block_array(1, nhalos+iy, nhalos+ix)
                  end do
               end do
               
               if (iblock == nblocks) then
                  filter_input_file%ncstatus = nf90_put_var(filter_input_file%ncid, dart_varids(varid), spatial_array)
               end if
            else
               ! This is one of the other non-spatial variables
               
               do iy = 1, truncated_nys_per_block
                  do ix = 1, truncated_nxs_per_block
                     icol = icol + 1
                     do iz = 1, nzs
                        variable_array(icol, iz, 1) = block_array(iz, nhalos+iy, nhalos+ix)
                     end do
                  end do
               end do

               if (iblock == nblocks) then
                  filter_input_file%ncstatus = nf90_put_var(filter_input_file%ncid, dart_varids(varid), variable_array)
               end if
            end if
         end if
      end do
   end do

   call nc_close_file(filter_input_file%ncid)

end subroutine model_to_dart

subroutine dart_to_model()

   integer :: iblock, icol, ix, iy, iz
   integer :: ntimes, nxs, nys, nzs, ncols
   integer :: filter_varid, block_varid, dimid
   character(len=NF90_MAX_NAME) :: filter_name, block_name
   integer :: filter_xtype, filter_nDimensions, filter_nAtts
   integer, dimension(NF90_MAX_VAR_DIMS) :: filter_dimids
   real(r4), allocatable, dimension(:, :, :) :: filter_array, block_array

   filter_output_file = assign_filter_file(dart_ensemble_member, filter_directory, filter_output_prefix, filter_output_suffix)

   ! The block files are read/write
   do iblock = 1, nblocks
      block_files(iblock)%ncid = nc_open_file_readwrite(block_files(iblock)%file_path)
   end do
   ! The dart file is read only
   filter_output_file%ncid = nc_open_file_readonly(filter_output_file%file_path)

   ! Get the variables list from the filter_output_file

   filter_output_file%ncstatus = nf90_inquire(filter_output_file%ncid, &
                                              filter_output_file%nDimensions, &
                                              filter_output_file%nVariables, &
                                              filter_output_file%nAttributes, &
                                              filter_output_file%unlimitedDimId, &
                                              filter_output_file%formatNum)

   filter_output_file%ncstatus = nf90_inq_dimid(filter_output_file%ncid, 'time', dimid)
   filter_output_file%ncstatus = nf90_inquire_dimension(filter_output_file%ncid, dimid, filter_name, ntimes)

   filter_output_file%ncstatus = nf90_inq_dimid(filter_output_file%ncid, 'z', dimid)
   filter_output_file%ncstatus = nf90_inquire_dimension(filter_output_file%ncid, dimid, filter_name, nzs)

   filter_output_file%ncstatus = nf90_inq_dimid(filter_output_file%ncid, 'col', dimid)
   filter_output_file%ncstatus = nf90_inquire_dimension(filter_output_file%ncid, dimid, filter_name, ncols)

   allocate(filter_array(ncols, nzs, ntimes))
   filter_array(:, :, :) = 0
   
   ! We need full blocks from the block files
   do filter_varid = 1, filter_output_file%nVariables
      icol = 0
      filter_output_file%ncstatus = nf90_inquire_variable(filter_output_file%ncid, filter_varid, filter_name, filter_xtype, filter_nDimensions, filter_dimids, filter_nAtts)
      
      if (filter_name /= 'time') then

         filter_output_file%ncstatus = nf90_get_var(filter_output_file%ncid, filter_varid, filter_array)
         
         do iblock = 1, nblocks

            if (filter_varid == 1 .and. iblock == 1) then
               block_files(iblock)%ncstatus = nf90_inq_dimid(block_files(iblock)%ncid, 'x', dimid)
               block_files(iblock)%ncstatus = nf90_inquire_dimension(block_files(iblock)%ncid, dimid, block_name, nxs)

               block_files(iblock)%ncstatus = nf90_inq_dimid(block_files(iblock)%ncid, 'y', dimid)
               block_files(iblock)%ncstatus = nf90_inquire_dimension(block_files(iblock)%ncid, dimid, block_name, nys)

               allocate(block_array(nzs, nys, nxs))
               block_array(:, :, :) = 0
            end if

            block_files(iblock)%ncstatus = nf90_inq_varid(block_files(iblock)%ncid, filter_name, block_varid)
            block_files(iblock)%ncstatus = nf90_get_var(block_files(iblock)%ncid, block_varid, block_array)

            do iy = 1, nys-2*nhalos
               do ix = 1, nxs-2*nhalos
                  icol = icol + 1
                  do iz = 1, nzs
                     block_array(iz, nhalos+iy, nhalos+ix) = filter_array(icol, iz, 1)
                  end do
               end do
            end do

            block_files(iblock)%ncstatus = nf90_put_var(block_files(iblock)%ncid, block_varid, block_array)
            print *, block_files(iblock)%ncstatus
         
         end do
      end if
   end do
   
   call nc_close_file(filter_output_file%ncid)

end subroutine dart_to_model

function get_ensemble_member_from_command_line() result(ensemble_member)
   ! Calls Fortran intrinsic subroutine get_command_argument and returns
   ! a string with four characters

   character(len=4) :: ensemble_member
   integer :: nargs

   nargs = command_argument_count()

   if (nargs /= 1) then
      call error_handler(E_ERR, 'get_ensemble_member_from_command_line', &
                         'ensemble member must be passed as a command line argument')
   end if

   call get_command_argument(1, ensemble_member)

end function get_ensemble_member_from_command_line

function assign_block_files_array(nblocks, ensemble_member, restart_directory, &
                                  restart_file_prefix, restart_file_middle, restart_file_suffix) &
                                  result(block_files)
   
   integer, intent(in)            :: nblocks
   character(len=4), intent(in)   :: ensemble_member
   character(len=*), intent(in) :: restart_directory
   character(len=*), intent(in) :: restart_file_prefix
   character(len=*), intent(in) :: restart_file_middle
   character(len=*), intent(in) :: restart_file_suffix
   type(file_type), allocatable, dimension(:) :: block_files
   character(len=4) :: block_name
   integer :: iblock

   allocate(block_files(nblocks))

   do iblock = 1, nblocks
      block_name = zero_fill(integer_to_string(iblock-1), 4)
      block_files(iblock)%file_path = trim(restart_directory) // trim(restart_file_prefix) // &
                                      ensemble_member // trim(restart_file_middle) // &
                                      block_name // trim(restart_file_suffix)
   end do

end function assign_block_files_array

function assign_filter_file(ensemble_member, filter_directory, filter_input_prefix, filter_input_suffix) &
                          result(filter_file)
   
   character(len=4), intent(in) :: ensemble_member
   character(len=*), intent(in) :: filter_directory
   character(len=*), intent(in) :: filter_input_prefix
   character(len=*), intent(in) :: filter_input_suffix
   type(file_type)              :: filter_file
   
   filter_file%file_path = trim(filter_directory) // trim(filter_input_prefix) // ensemble_member // trim(filter_input_suffix)

end function assign_filter_file

function integer_to_string(int) result(string)

   integer, intent(in) :: int
   character(len=varnamelength) :: string

   write(string,'(I0)') int
   string = trim(string)

end function integer_to_string

function zero_fill(string, desired_length) result(filled_string)

   character(len=*), intent(in) :: string
   integer, intent(in) :: desired_length

   character(len=varnamelength) :: filled_string
   integer :: length_of_string
   integer :: string_index, difference_of_string_lengths

   filled_string = ''
   length_of_string = len_trim(string)
   difference_of_string_lengths = desired_length - length_of_string

   if (difference_of_string_lengths < 0) then
      print *, 'Error: input string is longer than the desired output string.'
      stop
   else if (difference_of_string_lengths > 0) then
      do string_index = 1, difference_of_string_lengths
         filled_string(string_index:string_index) = '0'
      end do
   end if

   filled_string(difference_of_string_lengths+1:desired_length) = trim(string)

end function zero_fill

end module transform_state_mod
