"""
Input / output functions for reading / writing individual netCDF files from / to either S3 object storage
or to a file on a POSIX file system.

Author: Neil Massey
Date:   07/09/2017
"""

from _s3Client import *
from _s3Exceptions import *


class s3netCDFFile:
    """
       Class to return details of a netCDF file that may be on a POSIX file system, on S3 storage then
         streamed to a POSIX file cache or streamed from S3 directly into memory.
    """
    def __init__(self, filename = "", s3_uri = "", filemode = 'r', memory = None):
        """
        :param filename: the original filename on disk (or openDAP URI) or the filename of the cached file - i.e. where
                         the S3 file is streamed (for 'r' and 'a' filemodes) or created (for 'w' filemodes).
                         For memory streamed files this is the tempfile location.
        :param s3_uri: S3 URI for S3 files only
        :param filemode: 'r'ead | 'w'rite | 'a'ppend
        :param memory: the memory where the S3 file is streamed to, or None if filename on disk
        """

        self.filename = filename
        self.s3_uri = s3_uri
        self.filemode = filemode
        self.memory = memory
        self.format = 'NOT_NETCDF'
        self.cfa_file = None

    def __repr__(self):
        return "s3netCDFFile"

    def __str__(self):
        return "<s3netCDFFile> (filename='"+ self.filename +\
                                "', s3_uri='" + self.s3_uri +\
                                "', filemode='" + self.filemode +\
                                "', memory=" + str(self.memory) + ")"


def _get_netCDF_filetype(s3_client, bucket_name, object_name):
    """
       Read the first four bytes from the stream and interpret the magic number.
       See NC_interpret_magic_number in netcdf-c/libdispatch/dfile.c

       Check that it is a netCDF file before fetching any data and
       determine what type of netCDF file it is so the temporary empty file can
       be created with the same type.

       The possible types are:
       `NETCDF3_CLASSIC`, `NETCDF4`,`NETCDF4_CLASSIC`, `NETCDF3_64BIT_OFFSET` or `NETCDF3_64BIT_DATA
       or
       `NOT_NETCDF` if it is not a netCDF file - raise an exception on that

       :return: string filetype
    """
    # open the url/bucket/object as an s3_object and read the first 4 bytes
    try:
        s3_object = s3_client.get_partial(bucket_name, object_name, 0, 4)
    except BaseException:
        raise s3IOException(s3_client.get_full_url(bucket_name, object_name) + " not found")

    # start with NOT_NETCDF as the file_type
    file_version = 0
    file_type = 'NOT_NETCDF'

    # check whether it's a netCDF file (how can we tell if it's a NETCDF4_CLASSIC file?
    if s3_object.data[1:5] == 'HDF':
        # netCDF4 (HD5 version)
        file_type = 'NETCDF4'
        file_version = 5
    elif (s3_object.data[0] == '\016' and s3_object.data[1] == '\003' and s3_object.data[2] == '\023' and s3_object.data[3] == '\001'):
        file_type = 'NETCDF4'
        file_version = 4
    elif s3_object.data[0:3] == 'CDF':
        file_version = ord(s3_object.data[3])
        if file_version == 1:
            file_type = 'NETCDF3_CLASSIC'
        elif file_version == '2':
            file_type = 'NETCDF3_64BIT_OFFSET'
        elif file_version == '5':
            file_type = 'NETCDF3_64BIT_DATA'
        else:
            file_version = 1 # default to one if no version
    else:
        file_type = 'NOT_NETCDF'
        file_version = 0
    return file_type, file_version


def get_netCDF_file_details(filename, filemode='r', diskless=False):
    """
    Get the details of a netCDF file which is either stored in S3 storage or on POSIX disk.
    If the file is on S3 storage, and the filemode is 'r' or 'a' then it will be streamed to either the cache or
      into memory, depending on the filesize and the value of <max_file_size_for_memory> in the .s3nc4.json config file.

    :param filename: filename on POSIX / URI on S3 storage
    :param filemode: 'r'ead | 'w'rite | 'a'ppend
    :return: s3netCDFFile
    """

    # create file_details
    file_details = s3netCDFFile(filemode=filemode)

    # handle S3 file first
    if "s3://" in filename:

        # record the s3_uri - empty string indicates not an s3_uri file
        file_details.s3_uri = filename
        # Get the server, bucket and object from the URI: split the URI on "/" separator
        split_ep = filename.split("/")
        # get the s3 endpoint first
        s3_ep = "s3://" + split_ep[2]
        # now get the bucketname
        s3_bucket_name = split_ep[3]
        # finally get the object (prefix + object name) from the remainder of the
        s3_object_name = "/".join(split_ep[4:])

        # create the s3 client
        s3_client = s3Client(s3_ep)
        # get the full url for error messages
        full_url = s3_client.get_full_url(s3_bucket_name, s3_object_name)

        # if the filemode is 'r' or 'a' then we have to stream the file to either the cache or to memory
        if filemode == 'r' or filemode == 'a' or filemode == 'r+':

            # Check whether the object exists
            if not s3_client.object_exists(s3_bucket_name, s3_object_name):
                raise s3IOException("Error: " + full_url + " not found.")

            # check whether this object is a netCDF file
            file_type, file_version = _get_netCDF_filetype(s3_client, s3_bucket_name, s3_object_name)
            if file_type == "NOT_NETCDF" or file_version == 0:
                raise s3IOException("Error: " + full_url + " is not a netCDF file.")

            # retain the filetype
            file_details.format = file_type

            # check whether we should stream this object - use diskless to indicate the file should be read into
            # memory whatever its size
            if s3_client.should_stream_to_cache(s3_bucket_name, s3_object_name) and not diskless:
                # stream the file to the cache
                file_details.filename = s3_client.stream_to_cache(s3_bucket_name, s3_object_name)
            else:
                # the netCDF library needs to create a dummy file for files created from memory
                # one dummy file can be used for all of the memory streaming
                file_details.filename = s3_client.get_cache_location() + "/" + file_type + "_dummy.nc"
                # get the data from the object
                file_details.memory = s3_client.stream_to_memory(s3_bucket_name, s3_object_name)

        # if the filemode is 'w' then we just have to construct the cache filename and return it
        elif filemode == 'w':
            # get the cache file name
            file_details.filename = s3_client.get_cachefile_path(s3_bucket_name, s3_object_name)

        # the created file in
        else:
            # no other modes are supported
            raise s3APIException("Mode " + filemode + " not supported.")

    # otherwise just return the filename in file_details
    else:
        file_details.filename = filename

    return file_details