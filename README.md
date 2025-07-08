# calibreconverter
A simple tool to convert incoming e-book files to AZW3, MOBI, and EPUB and add the formats to Calibre

This is a tool I use for adding MOBI, AZW3, and EPUB formats to my calibre-server installation regardless of which of the three types were downloaded.  It will convert to the two missing formats and add all three to your library (for use on different devices/readers).  It can also add missing formats to existing books in the library by placing the files in the /new directory defined in the configuration file. 

1) Copy process_books.sh to a directory
2) chmod +x process_ebooks.sh
3) Copy ebook_process.conf to the same directory and edit it to reflect your paths and username
4) Schedule the script to run in crontab as desired

This script was tested on Ubuntu 22.04 and 24.04 and requires calibre-server to be installed on the system. 
