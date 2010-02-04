/*=========================================================================
  Program:   OsiriX

  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.

     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
=========================================================================*/

#import "BrowserControllerDCMTKCategory.h"
#import <OsiriX/DCMObject.h>
#import <OsiriX/DCM.h>
#import <OsiriX/DCMTransferSyntax.h>
#import "AppController.h"
#import "DCMPix.h"
#import "WaitRendering.h"

#undef verify
#include "osconfig.h" /* make sure OS specific configuration is included first */
#include "djdecode.h"  /* for dcmjpeg decoders */
#include "djencode.h"  /* for dcmjpeg encoders */
#include "dcrledrg.h"  /* for DcmRLEDecoderRegistration */
#include "dcrleerg.h"  /* for DcmRLEEncoderRegistration */
#include "djrploss.h"
#include "djrplol.h"
#include "dcpixel.h"
#include "dcrlerp.h"

#include "dcdatset.h"
#include "dcmetinf.h"
#include "dcfilefo.h"
#include "dcdebug.h"
#include "dcuid.h"
#include "dcdict.h"
#include "dcdeftag.h"

#define CHUNK_SUBPROCESS 500

extern NSRecursiveLock *PapyrusLock;

@implementation BrowserController (BrowserControllerDCMTKCategory)

+ (NSString*) compressionString: (NSString*) string
{
	if( [string isEqualToString: @"1.2.840.10008.1.2"])
		return NSLocalizedString( @"Uncompressed", nil);
	if( [string isEqualToString: @"1.2.840.10008.1.2.1"])
		return NSLocalizedString( @"Uncompressed", nil);
	if( [string isEqualToString: @"1.2.840.10008.1.2.2"])
		return NSLocalizedString( @"Uncompressed BigEndian", nil);
	
	return [NSString stringWithFormat:@"%s", dcmFindNameOfUID( [string UTF8String])];
}

#ifndef OSIRIX_LIGHT

- (NSData*) getDICOMFile:(NSString*) file inSyntax:(NSString*) syntax quality: (int) quality
{
	OFCondition cond;
	OFBool status = NO;
	
	DcmFileFormat fileformat;
	cond = fileformat.loadFile( [file UTF8String]);
	
	if (cond.good())
	{
		DcmXfer filexfer(fileformat.getDataset()->getOriginalXfer());
		DcmXfer xfer( [syntax UTF8String]);
		
		if( filexfer.getXfer() == xfer.getXfer())
			return [NSData dataWithContentsOfFile: file];
		
		if(  filexfer.getXfer() == EXS_JPEG2000 && xfer.getXfer() == EXS_JPEG2000LosslessOnly)
			return [NSData dataWithContentsOfFile: file];
			
		if(  filexfer.getXfer() == EXS_JPEG2000LosslessOnly && xfer.getXfer() == EXS_JPEG2000)
			return [NSData dataWithContentsOfFile: file];
		
		DCMObject *dcmObject = [[DCMObject alloc] initWithContentsOfFile: file decodingPixelData: NO];
		
		@try
		{
			[[NSFileManager defaultManager] removeItemAtPath: @"/tmp/wado-recompress.dcm"  error: nil];
			status = [dcmObject writeToFile: @"/tmp/wado-recompress.dcm" withTransferSyntax: [[[DCMTransferSyntax alloc] initWithTS: syntax] autorelease] quality: quality AET:@"OsiriX" atomically:YES];
		
			if( status == NO || [[NSFileManager defaultManager] fileExistsAtPath: @"/tmp/wado-recompress.dcm"] == NO)
			{
				status = [dcmObject writeToFile: @"/tmp/wado-recompress.dcm" withTransferSyntax: [DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax] quality: quality AET:@"OsiriX" atomically:YES];
			}
		}
		@catch (NSException *e)
		{
			NSLog( @"dcmObject writeToFile failed: %@", e);
		}
		
		[dcmObject release];
		
		NSData *data = [NSData dataWithContentsOfFile: @"/tmp/wado-recompress.dcm"];
		
		[[NSFileManager defaultManager] removeItemAtPath: @"/tmp/wado-recompress.dcm"  error: nil];
		
		return data;
	}
	
	return nil;
}

- (BOOL) needToCompressFile: (NSString*) path
{
	DcmFileFormat fileformat;
	OFCondition cond = fileformat.loadFile( [path UTF8String]);
	if( cond.good())
	{
		DcmDataset *dataset = fileformat.getDataset();
		DcmItem *metaInfo = fileformat.getMetaInfo();
		DcmXfer original_xfer(dataset->getOriginalXfer());
		if (original_xfer.isEncapsulated())
		{
			return NO;
		}
		else
		{
			const char *string = NULL;
			NSString *modality;
			if (dataset->findAndGetString(DCM_Modality, string, OFFalse).good() && string != NULL)
				modality = [NSString stringWithCString:string encoding: NSASCIIStringEncoding];
			else
				modality = @"OT";
			
			int resolution = 0;
			unsigned short rows = 0;
			if (dataset->findAndGetUint16( DCM_Rows, rows, OFFalse).good())
			{
				if( resolution == 0 || resolution > rows)
					resolution = rows;
			}
			unsigned short columns = 0;
			if (dataset->findAndGetUint16( DCM_Columns, columns, OFFalse).good())
			{
				if( resolution == 0 || resolution > columns)
					resolution = columns;
			}
			
			int quality, compression = [BrowserController compressionForModality: modality quality: &quality resolution: resolution];
			
			if( compression == compression_none)
				return NO;
				
			return YES;
		}
	}
	
	return NO;
}

- (BOOL)compressDICOMWithJPEG:(NSArray *) paths
{
	return [self compressDICOMWithJPEG: paths to: nil];
}

- (BOOL)compressDICOMWithJPEG:(NSArray *) paths to:(NSString*) dest
{
//	DCMObject *dcmObject = [[DCMObject alloc] initWithContentsOfFile: [paths lastObject] decodingPixelData: NO];
//							
//	BOOL succeed = NO;
//	
//	@try
//	{
//		DCMTransferSyntax *tsx = [DCMTransferSyntax JPEG2000LossyTransferSyntax]; // JPEG2000LosslessTransferSyntax];
//		succeed = [dcmObject writeToFile: [[paths lastObject] stringByAppendingString:@"aa.dcm"] withTransferSyntax: tsx quality: DCMLowQuality AET:@"OsiriX" atomically:YES];
//	}
//	@catch (NSException *e)
//	{
//		NSLog( @"dcmObject writeToFile failed: %@", e);
//	}
//	[dcmObject release];
//	
//	return YES;

// ********

//	NSLog( @"** START");
//	NSString *dest2 = [paths lastObject];
//	
//	DCMObject *dcmObject = [[DCMObject alloc] initWithContentsOfFile: [paths lastObject] decodingPixelData: NO];
//	
//	BOOL succeed = NO;
//	
//	@try
//	{
//		succeed = [dcmObject writeToFile: [dest2 stringByAppendingString: @" temp"] withTransferSyntax:[DCMTransferSyntax JPEG2000LossyTransferSyntax] quality: 0 AET:@"OsiriX" atomically:YES];
//	}
//	@catch (NSException *e)
//	{
//		NSLog( @"dcmObject writeToFile failed: %@", e);
//	}
//	[dcmObject release];
//	
//	if( succeed)
//	{
//		if( dest2 == [paths lastObject])
//			[[NSFileManager defaultManager] removeFileAtPath: [paths lastObject] handler: nil];
//		[[NSFileManager defaultManager] movePath: [dest2 stringByAppendingString: @" temp"] toPath: dest2 handler: nil];
//	}
//	else
//	{
//		NSLog( @"failed to compress file: %@", [paths lastObject]);
//		[[NSFileManager defaultManager] removeFileAtPath: [dest2 stringByAppendingString: @" temp"] handler: nil];
//	}
//	NSLog( @"** END");
	
	if( dest == nil)
		dest = @"sameAsDestination";
	
	
	int total = [paths count];
	
	for( int i = 0; i < total;)
	{
		int no;
		
		if( i + CHUNK_SUBPROCESS >= total) no = total - i; 
		else no = CHUNK_SUBPROCESS;
		
		NSRange range = NSMakeRange( i, no);
		
		id *objs = (id*) malloc( no * sizeof( id));
		if( objs)
		{
			[paths getObjects: objs range: range];
			
			NSArray *subArray = [NSArray arrayWithObjects: objs count: no];
			
			NSTask *theTask = [[NSTask alloc] init];
			@try
			{
				[theTask setArguments: [[NSArray arrayWithObjects: dest, @"compress", nil] arrayByAddingObjectsFromArray: subArray]];
				[theTask setLaunchPath:[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"/Decompress"]];
				[theTask launch];
				while( [theTask isRunning]) [NSThread sleepForTimeInterval: 0.01];
			}
			@catch ( NSException *e)
			{
				NSLog( @"***** compressDICOMWithJPEG exception : %@", e);
			}
			[theTask release];
			
			free( objs);
		}
		
		i += no;
	}
	
	return YES;
}

- (BOOL)decompressDICOMList:(NSArray *) files to:(NSString*) dest
{
//	DCMObject *dcmObject = [[DCMObject alloc] initWithContentsOfFile: [files lastObject] decodingPixelData: NO];
//							
//	BOOL succeed = NO;
//	
//	@try
//	{
//		DCMTransferSyntax *tsx = [DCMTransferSyntax ExplicitVRLittleEndianTransferSyntax]; // JPEG2000LosslessTransferSyntax];
//		succeed = [dcmObject writeToFile: [[files lastObject] stringByAppendingString:@"bb.dcm"] withTransferSyntax: tsx quality: 1 AET:@"OsiriX" atomically:YES];
//	}
//	@catch (NSException *e)
//	{
//		NSLog( @"dcmObject writeToFile failed: %@", e);
//	}
//	[dcmObject release];
//	
//	return YES;
	
	if( dest == nil)
		dest = @"sameAsDestination";
	
	int total = [files count];
	
	for( int i = 0; i < total;)
	{
		int no;
		
		if( i + CHUNK_SUBPROCESS >= total) no = total - i; 
		else no = CHUNK_SUBPROCESS;
		
		NSRange range = NSMakeRange( i, no);
		
		id *objs = (id*) malloc( no * sizeof( id));
		if( objs)
		{
			[files getObjects: objs range: range];
			
			NSArray *subArray = [NSArray arrayWithObjects: objs count: no];
			
			NSTask *theTask = [[NSTask alloc] init];
			
			@try
			{
				NSArray *parameters = [[NSArray arrayWithObjects: dest, @"decompressList", nil] arrayByAddingObjectsFromArray: subArray];
				
				[theTask setArguments: parameters];
				[theTask setLaunchPath:[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"/Decompress"]];
				[theTask launch];
				
				while( [theTask isRunning]) [NSThread sleepForTimeInterval: 0.01];
			}
			@catch ( NSException *e)
			{
				NSLog( @"***** decompressDICOMList exception : %@", e);
			}
			[theTask release];
			
			free( objs);
		}
		
		i += no;
	}
	
	return YES;
}

- (BOOL) testFiles: (NSArray*) files;
{
	WaitRendering *splash = nil;
	NSMutableArray *tasksArray = [NSMutableArray array];
	int CHUNK_SIZE;
	
	if( [NSThread isMainThread])
	{
		splash = [[WaitRendering alloc] init: NSLocalizedString( @"Validating files...", nil)];
		[splash showWindow:self];
	}
	
	BOOL succeed = YES;
	
	int total = [files count];
	
	CHUNK_SIZE = total / MPProcessors();
	
	CHUNK_SIZE += 20;
	
	@try
	{
		for( int i = 0; i < total;)
		{
			int no;
			
			if( i + CHUNK_SIZE >= total) no = total - i; 
			else no = CHUNK_SIZE;
			
			NSRange range = NSMakeRange( i, no);
			
			id *objs = (id*) malloc( no * sizeof( id));
			if( objs)
			{
				[files getObjects: objs range: range];
				
				NSArray *subArray = [NSArray arrayWithObjects: objs count: no];
				
				NSTask *theTask = [[[NSTask alloc] init] autorelease];
				
				[tasksArray addObject: theTask];
				
				NSArray *parameters = [[NSArray arrayWithObjects: @"unused", @"testFiles", nil] arrayByAddingObjectsFromArray: subArray];
				
				[theTask setArguments: parameters];
				[theTask setLaunchPath:[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"/Decompress"]];
				[theTask launch];
				
				free( objs);
			}
			
			i += no;
		}
	}
	@catch ( NSException *e)
	{
		NSLog( @"***** testList exception : %@", e);
		succeed = NO;
	}
	
	NSLog( @"Number of sub-process for testFiles: %d", [tasksArray count]);
	
	for( NSTask *t in tasksArray)
	{
		[t waitUntilExit];
		
		if( [t terminationStatus] != 0)
			succeed = NO;
	}
	
	[splash close];
	[splash release];
	
	if( succeed == NO)
		NSLog( @"******* test Files FAILED : one of more of these files are corrupted : %@", files);
	
	return succeed;
}

#endif

@end
