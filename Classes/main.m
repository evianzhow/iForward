#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AddressBook/AddressBook.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <curl/curl.h>
#include <time.h>
#include <unistd.h>
#include <sqlite3.h>
#include <assert.h>


static const char *text[]={
  "From: iForward<%s>\r\n\r\n",
  "To: %s\r\n",
  "Subject: %s\r\n",
  "Content-Type: text/html; charset=utf-8\r\n",
  "\r\n",
  "\r\n",
  "\r\n",
  "%s",
  NULL
};

struct WriteThis {
  int counter;
};

#define DB_CALL4 "/private/var/wireless/Library/CallHistory/call_history.db"
#define DB_CALL2 "/private/var/mobile/Library/CallHistory/call_history.db"
#define DB_CALL8 "/var/mobile/Library/CallHistoryDB/CallHistory.storedata"
//#define DB_CALL6 "/private/var/wireless/Library/CallHistory/call_history.db"
#define DB_SMS "/private/var/mobile/Library/SMS/sms.db"
#define DB_VOICE "/private/var/mobile/Library/Voicemail/voicemail.db"
#define DB_LOCAL "/Library/Application\ Support/iForward/iForward.db"
#define DB_AB "/var/mobile/Library/AddressBook/AddressBook.sqlitedb"

char host_port[70];
char host[60];
char port[10];
char pw[100];
char toEmail[60];
char fromEmail[60];
char inSubjects[3][60];
char outSubjects[3][60];
char subject[60];
NSMutableString *content = nil;
int isSMS = 0;
int isCall = 0;
int isVoice = 0;
int isIncoming = 0;
int inEnabled[3];
int outEnabled[3];
int attachVoicemail = 1;
int attachMMS = 0;
int current_message = 0;
int lastVoicemail = -1;
int version = 0;
int debugOn = 0;

struct mmsFile {
  char *fileName;
  char *contentType;
  char *filePath;
  struct mmsFile* nextFile;
};

struct mmsFile *mmsFilesHead = NULL;

NSMutableString *MMSBuffer = nil;
NSString *uid = nil;
NSComparisonResult Gorder = nil;
int sqlType = 0;

#define CALL 0
#define SMS 1
#define VOICE 2

#define DISPLAY_ERROR(x,a) \
{ \
  CFOptionFlags responseFlags = 0; \
  CFStringRef iError; \
  if (a != 0) iError = CFStringCreateWithFormat(NULL, NULL, CFSTR("%s Error Code: %d"), x, a); \
  else iError = CFSTR(x); \  
  CFUserNotificationDisplayAlert(20.0, 3, NULL, NULL, NULL, CFSTR("iForward Error"), iError, CFSTR("OK"), NULL, NULL, &responseFlags); \
} \

#define NSLOG(...) \
{ \
  if (debugOn) NSLog(__VA_ARGS__); \
} \

/*
** Translation Table as described in RFC1113
*/
static const char cb64[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/*
** Translation Table to decode (created by author)
*/
static const char cd64[]="|$$$}rstuvwxyz{$$$$$$$>?@ABCDEFGHIJKLMNOPQRSTUVW$$$$$$XYZ[\\]^_`abcdefghijklmnopq";

/*
** encodeblock
**
** encode 3 8-bit binary bytes as 4 '6-bit' characters
*/
void encodeblock( unsigned char in[3], unsigned char out[4], int len )
{
    out[0] = cb64[ in[0] >> 2 ];
    out[1] = cb64[ ((in[0] & 0x03) << 4) | ((in[1] & 0xf0) >> 4) ];
    out[2] = (unsigned char) (len > 1 ? cb64[ ((in[1] & 0x0f) << 2) | ((in[2] & 0xc0) >> 6) ] : '=');
    out[3] = (unsigned char) (len > 2 ? cb64[ in[2] & 0x3f ] : '=');
}

/*
** encode
**
** base64 encode a stream adding padding and line breaks as per spec.
*/
void encode( FILE *infile, FILE *outfile, int linesize )
{
    unsigned char in[3], out[4];
    int i, len, blocksout = 0;

    while( !feof( infile ) ) {
        len = 0;
        for( i = 0; i < 3; i++ ) {
            in[i] = (unsigned char) getc( infile );
            if( !feof( infile ) ) {
                len++;
            }
            else {
                in[i] = 0;
            }
        }
        if( len ) {
            encodeblock( in, out, len );
            for( i = 0; i < 4; i++ ) {
                fprintf(outfile, "%c", out[i]);
            }
            blocksout++;
        }
        if( blocksout >= (linesize/4) || feof( infile ) ) {
            if( blocksout ) {
                fprintf( outfile, "\r\n" );
            }
            blocksout = 0;
        }
    }
}

NSMutableString * GetContactName(const char *number)
{

  CFArrayRef allPeople = nil;

  //char name[100];
  //strcpy (name, "\0");
  NSMutableString *name = [[NSMutableString alloc] initWithString:@""];
  
  if (number == NULL || strlen(number) == 0)
   return name;
    
  @try {

      ABAddressBookRef m_addressbook = ABAddressBookCreate();
      if (!m_addressbook) {
        NSLOG(@"Failed opening AB\n");
        return name;
      }
      else NSLOG(@"opened AB\n");
    
      // can be cast to NSArray, toll-free
      allPeople = ABAddressBookCopyArrayOfAllPeople(m_addressbook);
      if (allPeople == nil)
        return name;
    
          
    CFIndex nPeople = CFArrayGetCount(allPeople);
    NSLOG(@"count=%d,number=%s", nPeople, number);
    if (nPeople > 5000)  { NSLOG(@">5000"); return name; }
    
    for (int i=0;i < nPeople;i++) { 
      ABRecordRef ref = CFArrayGetValueAtIndex(allPeople,i);

      ABMutableMultiValueRef multi = ABRecordCopyValue(ref, kABPersonPhoneProperty);

      for (CFIndex i = 0; i < ABMultiValueGetCount(multi); i++)
      {
          NSString *phoneNumberLabel = (NSString*) ABMultiValueCopyLabelAtIndex(multi, i);
          NSString *phoneNumber      = (NSString*) ABMultiValueCopyValueAtIndex(multi, i);
          const char* num = [phoneNumber UTF8String];
          NSLOG(@"number=%s", num);

          char all_numeric1[40];
          char all_numeric2[40];
          char the_num[40];
          char contact_num[40];
          
          strcpy(all_numeric2, "");
          strcpy(all_numeric1, "");
          
          for (int ii=0; ii < strlen(num); ii++)
          {
            if (isdigit(num[ii]))
            {
              sprintf(all_numeric1, "%s%c", all_numeric1, num[ii]);
            }
      if (ii == 39) break;
          }
          
          for (int bb=0; bb < strlen(number); bb++)
          {
            if (isdigit(number[bb]))
            {
              sprintf(all_numeric2, "%s%c", all_numeric2, number[bb]);
            }
      if (bb == 39) break;
          }
          
          if (strlen(all_numeric2) > 0 && strlen(all_numeric2) > 0)
          {
            if (all_numeric2[0] == '1' && all_numeric1[0] != '1')
            {
              //printf("adding a 1 to all numeric1");
              sprintf(contact_num, "1%s", all_numeric1);
            }
            else sprintf(contact_num, all_numeric1);
            
            if (all_numeric1[0] == '1' && all_numeric2[0] != '1')
            {
              //printf("adding a 1 to all numeric2");
              sprintf(the_num, "1%s", all_numeric2);
            }
            else sprintf(the_num, all_numeric2);
          }            
          
            
          //printf("all_numeric1=%s,all_numeric2=%s",all_numeric1, all_numeric2);
          
          if (strcmp(contact_num, the_num) == 0)
          {
            NSLOG(@"matched");

            NSString *contactFirst = (NSString*) ABRecordCopyValue(ref, kABPersonFirstNameProperty);
              if (contactFirst != nil && [contactFirst length] > 0)
                [name appendFormat: @"%@", contactFirst];

              NSString *contactLast = (NSString*) ABRecordCopyValue(ref, kABPersonLastNameProperty);
              if (contactLast != nil && [contactLast length] > 0)
                [name appendFormat: @" %@", contactLast];
                
              NSLOG(@"ret names=%@", name);
              
              return name;

          }
      }
      //CFRelease(multi);
      //CFRelease(ref);
    }
  }
  @catch (NSException * e) {
    NSLOG(@"Exception: %@", e);
    return name;
 }

  //CFRelease(allPeople);
  NSLOG(@"no match");
  return name;
}


NSMutableString* GetContactName6(const char *number)
{

  NSMutableString *name = [[NSMutableString alloc] initWithString:@""];
  if (number == (char*) NULL || strlen(number) == 0)
   return name;
   
  const char* cmd = "select a.First, a.Last, v.Value from ABPerson as a, ABMultiValue as v where v.record_id = a.rowid;";
  
  sqlite3 * db;
  sqlite3_stmt * stmt;
  int rc;  
  rc = sqlite3_open(DB_AB, &db);
  sqlite3_prepare_v2(db, cmd, strlen(cmd) + 1, & stmt, NULL);
  
  while (1)
  {
    int s;
    s = sqlite3_step(stmt);
    
    if (s == SQLITE_ROW) 
    {
      const char* num = (char*) sqlite3_column_text(stmt, 2);
          NSLOG(@"got %s, book number=%s", number, num);
      if (num == (char*) NULL || strlen(num) == 0) continue;
      
          char all_numeric1[40];
          char all_numeric2[40];
          char the_num[40];
          char contact_num[40];
          
          strcpy(all_numeric2, "");
          strcpy(all_numeric1, "");
          
          for (int ii=0; ii < strlen(num); ii++)
          {
            if (isdigit(num[ii]))
            {
              sprintf(all_numeric1, "%s%c", all_numeric1, num[ii]);
            }
      if (ii==39) break;
          }
          
          for (int bb=0; bb < strlen(number); bb++)
          {
            if (isdigit(number[bb]))
            {
              sprintf(all_numeric2, "%s%c", all_numeric2, number[bb]);
            }
      if (bb == 39) break;
          }
          
          if (strlen(all_numeric2) > 0 && strlen(all_numeric2) > 0)
          {
            if (all_numeric2[0] == '1' && all_numeric1[0] != '1')
            {
              //printf("adding a 1 to all numeric1");
              sprintf(contact_num, "1%s", all_numeric1);
            }
            else sprintf(contact_num, all_numeric1);
            
            if (all_numeric1[0] == '1' && all_numeric2[0] != '1')
            {
              //printf("adding a 1 to all numeric2");
              sprintf(the_num, "1%s", all_numeric2);
            }
            else sprintf(the_num, all_numeric2);
          }            
          
            
          //printf("all_numeric1=%s,all_numeric2=%s",all_numeric1, all_numeric2);
          
          if (strcmp(contact_num, the_num) == 0)
          {
            NSLOG(@"matched");
              
        char *contactFirst = (char*) sqlite3_column_text(stmt, 0);
        if (contactFirst != (char*) NULL && strlen(contactFirst) > 0)
                [name appendFormat: @"%@", [NSString stringWithUTF8String: contactFirst]];
              
              char *contactLast = (char*) sqlite3_column_text(stmt, 1); 
              if (contactLast != (char*) NULL && strlen(contactLast) > 0)
                [name appendFormat: @" %@", [NSString stringWithUTF8String: contactLast]];
                
              NSLOG(@"ret names=%@", name);
              
              return name;

          }
      }
    else if (s == SQLITE_DONE)
      {
        break;
      }
      else 
      {
        printf ("Failed opening in %s.\n", DB_AB);
        exit (1);
      }
  }
  
  sqlite3_finalize(stmt);
  sqlite3_close(db);
   
  NSLOG(@"no match");
  [name appendFormat: @" %@", [NSString stringWithUTF8String: number]];
  return name;
}


char* GetRecipients(char* recp)
{
        NSMutableString *nsData = [[NSMutableString alloc] initWithUTF8String:recp];
        [nsData setString: [nsData stringByReplacingOccurrencesOfString:@"\n" withString:@"<br\>"]];
        [nsData setString: [nsData stringByReplacingOccurrencesOfString:@"\r" withString:@"<br\>"]];
          
        /*
        FILE* plist = fopen( "/Library/Application\ Support/iForward/tmp_buff.txt", "w" );
        fprintf(plist,recp);
        fclose(plist);
         
        // Build the array from the plist  
        NSMutableArray *array2 = [[NSMutableArray alloc] initWithContentsOfFile:@"/Library/Application\ Support/iForward/tmp_buff.txt"];
         
        NSMutableString *nsData = [[NSMutableString alloc] initWithString:@""];
          
        NSUInteger count = [array2 count];
        for (NSUInteger i = 0; i < count; i++) {
          
          NSString *str = [array2 objectAtIndex: i];
          if (i<count-1)
            [nsData appendFormat: @"%s,", str];
          else
            [nsData appendFormat: @"%s", str];
        }
        */
        
        return [nsData UTF8String];
}


/**
select address,date,flags,duration from call order by ROWID desc limit %d;
**/
int ExecCallCommand(const char *cmd, int limit, int ver)
{
  sqlite3 * db;
  //char * sql;
  sqlite3_stmt * stmt;
  int rc;
  if (sqlType == 1)
    rc = sqlite3_open(DB_CALL8, &db);
  else if (version == 4)
    rc = sqlite3_open(DB_CALL4, &db);
  else
    rc = sqlite3_open(DB_CALL2, &db);
    
  sqlite3_prepare_v2(db, cmd, strlen(cmd) + 1, & stmt, NULL);
  
  int times = 0;
  while (1)
  {
    int s;
    s = sqlite3_step(stmt);
    //limit to 5 per email, take last 5
    if (times < limit-5)
    {
      times++;
      continue;
    } 
    
    if (s == SQLITE_ROW) 
    {
        const unsigned char* address;
        char start_date[60]; int number;
        int flags;
        //char end_date[60];
        
        address = sqlite3_column_text(stmt, 0);
        
        number = sqlite3_column_int(stmt, 1);
        struct tm tim;
        time_t now;
        flags = sqlite3_column_int(stmt, 2);
        char from_to[5];

        if (sqlType == 1)
        {
          time(&now);
          if (flags == 2)
          {
            isIncoming = 1;
            strcpy(from_to, "from");
          }
          else
          {
            isIncoming = 0;
            strcpy(from_to, "to");
          }
        }
        else
        {
          now = (time_t) number;
          int f = flags & (1 << 0);
          if (f == 0)
          {
              isIncoming = 1;
              strcpy(from_to, "from");
          }
          else
          {
              isIncoming = 0;
              strcpy(from_to, "to");
          }
        }

        if (now > 0) 
        {
          tim = *(localtime(&now));
          strftime(start_date,30,"%b %d, %Y  %I:%M:%S %p",&tim);
        }

        NSLOG(@"flags=%d,from_to=%s", flags, from_to);
        
        //char cname[100];
        //strcpy(cname, GetContactName(address));
        NSMutableString *cname = nil;
    if (ver == 1) cname = GetContactName6(address);
    else cname = GetContactName(address);
    
        //NSLOG(@"cname=%@", cname);
        int dur = 0;
        dur = sqlite3_column_int(stmt, 3);
        char t[60];
        int minutes, seconds;
        if (dur != 0) {
          seconds = dur % 60;
          dur = dur - seconds;
          minutes = (dur / 60) % 60;
          sprintf(t, "%d min %d sec", minutes, seconds);
        }
        else 
          sprintf(t, "0 sec");
        
    [content appendFormat: @"<h3>New Call at %s</h3> %s %@ (%s)  duration %s<br/>", start_date, from_to,
          cname, address, t];

    }
    else if (s == SQLITE_DONE)
    {
        break;
    }
    else 
    {
        printf ("Failed opening in %s.\n", DB_CALL4);
        exit (1);
    }
    times++;
  }
  sqlite3_finalize(stmt);
  sqlite3_close(db);
  return 1;
}


char* GetMMSFilePath(char* fname)
{

  NSString *docsDir = @"/var/mobile/Library/SMS";
  NSFileManager *localFileManager=[[NSFileManager alloc] init];
  NSDirectoryEnumerator *dirEnum =
      [localFileManager enumeratorAtPath:docsDir];
  NSString *file;
  while (file = [dirEnum nextObject]) {
      //NSLOG(@"looking at file =%@", file);
      if (strstr([file UTF8String], fname) != NULL) {
          return [file UTF8String];
      }
  }
  [localFileManager release];
  return NULL;
  
}


int CheckToEmail()
{
    NSString *fe = [[NSString alloc] initWithUTF8String: toEmail];
    NSRange r = [fe rangeOfString: @"@me." options:NSCaseInsensitiveSearch];
    if (fe != nil && r.location != NSNotFound) {
      char icloud[100];
      sprintf(icloud, "iCloud-%s", toEmail);
      //check for only already set up emails
      NSString *docsDir = @"/var/mobile/Library/Mail";
      NSFileManager *localFileManager=[[NSFileManager alloc] init];
      NSDirectoryEnumerator *dirEnum =
          [localFileManager enumeratorAtPath:docsDir];
      NSString *file;
      while (file = [dirEnum nextObject]) {
          if (strstr([file UTF8String], "iCloud-") != NULL) {
            NSString *ic = [[NSString alloc] initWithUTF8String: icloud];
            NSRange r = [ic rangeOfString: file options:NSCaseInsensitiveSearch];
            if (ic !=nil && r.location != NSNotFound) {
              printf("To Email found iCloud\n");
              return 1;
            }
          }
      }
      [localFileManager release];
    }
    
    NSString *filePath = [[NSString alloc] initWithUTF8String:"/private/var/mobile/Library/Mail/metadata.plist"];
    NSMutableDictionary* metadata = [[NSMutableDictionary alloc] initWithContentsOfFile: filePath];
    NSMutableDictionary* fetchingdata = [metadata objectForKey:@"FetchingData"];
    
    if (fetchingdata != nil)
    {
      for (NSString *key in fetchingdata) {
        
        NSMutableString *nsData = [[NSMutableString alloc] initWithString:key];
        [nsData setString: [nsData stringByReplacingOccurrencesOfString:@"%40" withString:@"@"]];
        //printf("key=%s", [nsData UTF8String]);
        NSRange r = [nsData rangeOfString: fe options:NSCaseInsensitiveSearch];
        if (nsData != nil && r.location != NSNotFound) {
          printf("To Email found 1\n");
          return 1;
        }
      }
    }
    
    //check for only already set up emails
    NSString *docsDir = @"/var/mobile/Library/Mail";
    NSFileManager *localFileManager=[[NSFileManager alloc] init];
    NSDirectoryEnumerator *dirEnum =
        [localFileManager enumeratorAtPath:docsDir];
    NSString *file;
    while (file = [dirEnum nextObject]) {
        if (strstr([file UTF8String], "-") != NULL) {
          NSRange r = [file rangeOfString: fe options:NSCaseInsensitiveSearch];
          if (r.location != NSNotFound) {
            printf("To Email found 2\n");
            return 1;
          }
        }
    }
    [localFileManager release];

    return 0;
}

void AppendMMSBuffer(int rowid, int limit)
{
  char cmd[400];
  const char *sqll = "select m.text,m.address,m.date,m.flags,p.data,m.ROWID,p.content_type,m.recipients,p.part_id from message m LEFT JOIN msg_pieces p on m.ROWID = p.message_id where m.ROWID=%d order by m.ROWID desc;";

  sprintf(cmd, sqll, rowid, limit);
  //printf("ccmd=%s", cmd);
  
  sqlite3 * db;
  //char * sql;
  sqlite3_stmt * stmt;
  int rc;
    
  rc = sqlite3_open(DB_SMS, &db);
  sqlite3_prepare_v2(db, cmd, strlen(cmd) + 1, & stmt, NULL);
  int row_count = 0;
  while (1)
  {  
    int s;
    s = sqlite3_step(stmt);
    
    if (s == SQLITE_ROW) 
    {
    
      char *text = (char*) sqlite3_column_text(stmt, 4);
     
      if (text && strlen(text) > 0)
      {
      
      if (MMSBuffer == nil)
        MMSBuffer = [[NSMutableString alloc] initWithString: @"MMS content "];
      else
        [MMSBuffer appendString: [[NSMutableString alloc] initWithString: @"<br/>MMS content "]];
      
      //if (attachMMS)
        //AddMMSFile(nsData);
      NSMutableString *nsData = [[NSMutableString alloc] initWithUTF8String: text];
      [nsData setString: [nsData stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"]];
      [nsData setString: [nsData stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"]];
      [nsData setString: [nsData stringByReplacingOccurrencesOfString:@"\n" withString:@"<br\>"]];
      [nsData setString: [nsData stringByReplacingOccurrencesOfString:@"\r" withString:@"<br\>"]]; 
      
      [MMSBuffer appendFormat: @"%@<br/>", nsData];
      }
      
      char f[20];
      int part_id = (int) sqlite3_column_int(stmt, 8);
      sprintf(f, "%d-%d.jpg", rowid, part_id);
      //NSLOG(@"filepath %d-%d=%s",rowid,part_id,GetMMSFilePath(f));
    
    }
    else if (s == SQLITE_DONE)
    {
        break;
    }
    else 
    {
        NSLOG(@"Failed opening %s.\n", DB_SMS);
        exit (1);
    }
  }
  sqlite3_finalize(stmt);
  sqlite3_close(db);
    
  //NSLOG(@"MMSBuffer=%@", MMSBuffer);
  return;
}

void AppendMMSBuffer6(int rowid, int limit)
{
  char *cmd;
  const char *t = "select a.filename, a.mime_type from message m JOIN message_attachment_join j on m.ROWID = j.message_id JOIN attachment a on a.ROWID = j.attachment_id where m.ROWID=%d order by m.ROWID desc;";
  cmd = (char*) malloc((strlen(t) + 20) * sizeof(char));
  assert(cmd != (char*) NULL);
  sprintf(cmd, t, rowid);
    
  sqlite3 * db;
  sqlite3_stmt * stmt;
  int rc;  
  rc = sqlite3_open(DB_SMS, &db);
  sqlite3_prepare_v2(db, cmd, strlen(cmd) + 1, & stmt, NULL);
  
  while (1)
  {
    int s;
    s = sqlite3_step(stmt);
    
    if (s == SQLITE_ROW) 
    {
    
      const char *text = (char*) sqlite3_column_text(stmt, 0);
    
      if (text && strlen(text) > 0)
      {
      
      if (MMSBuffer == nil)
        MMSBuffer = [[NSMutableString alloc] initWithString: @"MMS filename "];
      else
        [MMSBuffer appendString: [[NSMutableString alloc] initWithString: @"<br/>MMS filename "]];
    
    NSMutableString *nsData = [[NSMutableString alloc] initWithUTF8String: text];
     
    if (attachMMS)
    {
      char *mime_type = (char*) sqlite3_column_text(stmt, 1);
      NSLOG(@"mime_type=%s,text=%s",mime_type,text);
      char *file = strtok(text, "/");
      char fname[100];
      char fpath[300];
      
      assert(fname != NULL);
      do
      {
        strcpy(fname,file);
      } while((file = strtok(NULL, "/")) != NULL);//get last token
      
      NSLOG(@"file=%s,size=%d,length",fname,[nsData length]);
      
      assert(fpath != NULL);
      
      strncpy(fpath, [nsData UTF8String]+1, [nsData length]-1);
      fpath[[nsData length]-1] = '\0';
        NSLOG(@"fpath=%s,length=%d,fname=%d",fpath,[nsData length],strlen(fname));
      
      
      if (mmsFilesHead == NULL)
      {
      mmsFilesHead = malloc(sizeof(struct mmsFile));
      assert(mmsFilesHead != NULL);
      
      mmsFilesHead->fileName = malloc(strlen(fname)+1 * sizeof(char));
      assert(mmsFilesHead->fileName != NULL);
      strcpy(mmsFilesHead->fileName,fname);
      
      mmsFilesHead->contentType = malloc(strlen(mime_type)+1 * sizeof(char));
      assert(mmsFilesHead->contentType != NULL);
      strcpy(mmsFilesHead->contentType,mime_type);
      
      mmsFilesHead->filePath = malloc(strlen(fpath)+1 * sizeof(char));
      assert(mmsFilesHead->filePath != NULL);
      strcpy(mmsFilesHead->filePath,fpath);
      
      NSLOG(@"first node filepath=%s,file=%s\n", mmsFilesHead->filePath, mmsFilesHead->fileName);
      mmsFilesHead->nextFile = NULL;
      }
      else
      {
         struct mmsFile *tmpMmsFilesHead = mmsFilesHead;
         
         while(1) {
          if (tmpMmsFilesHead->nextFile != NULL) tmpMmsFilesHead = tmpMmsFilesHead->nextFile;
          else break;
         }
          
         
          tmpMmsFilesHead->nextFile = malloc(sizeof(struct mmsFile));
          assert(tmpMmsFilesHead->nextFile != NULL);
          tmpMmsFilesHead = tmpMmsFilesHead->nextFile;
      
        tmpMmsFilesHead->fileName = malloc(strlen(fname)+1 * sizeof(char));
        assert(tmpMmsFilesHead->fileName != NULL);
        strcpy(tmpMmsFilesHead->fileName,fname);
        
        tmpMmsFilesHead->contentType = malloc(strlen(mime_type)+1 * sizeof(char));
        assert(tmpMmsFilesHead->contentType != NULL);
        strcpy(tmpMmsFilesHead->contentType,mime_type);
        
        tmpMmsFilesHead->filePath = malloc(strlen(fpath)+1 * sizeof(char));
        assert(tmpMmsFilesHead->filePath != NULL);
        strcpy(tmpMmsFilesHead->filePath,fpath);
        tmpMmsFilesHead->nextFile = NULL;
        
        NSLOG(@"new node filepath=%s,file=%s\n", tmpMmsFilesHead->filePath, tmpMmsFilesHead->fileName);
      }
      }
    
      [nsData setString: [nsData stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"]];
      [nsData setString: [nsData stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"]];
      [nsData setString: [nsData stringByReplacingOccurrencesOfString:@"\n" withString:@"<br\>"]];
      [nsData setString: [nsData stringByReplacingOccurrencesOfString:@"\r" withString:@"<br\>"]]; 
      
      [MMSBuffer appendFormat: @"%@<br/>", nsData];
      }
      
    }
    else if (s == SQLITE_DONE)
    {
        break;
    }
    else 
    {
        NSLOG(@"Failed opening %s.\n", DB_SMS);
        exit (1);
    }
  }
  sqlite3_finalize(stmt);
  sqlite3_close(db);
    
  //NSLOG(@"MMSBuffer=%@", MMSBuffer);
  return;
}

NSString* GetiOS6ChatAddresses(char* chatid)
{
    NSMutableString *nsAddress = nil;
  
  if (chatid == (char*) NULL || strlen(chatid) == 0)
  {
    return nsAddress;
  }
  
  const char* t = "select distinct h.id from handle h LEFT JOIN chat_handle_join j on j.handle_id = h.ROWID JOIN chat c on c.ROWID = j.chat_id where c.room_name='%s';";
    char *cmd;
    cmd = (char*) malloc((strlen(t) + strlen(chatid) + 2) * sizeof(char));
  assert(cmd != (char*) NULL);
  sprintf(cmd, t, chatid);
    sqlite3 * db;
    //char * sql;
    sqlite3_stmt * stmt;
    int rc;
    int row_count = 0;
  
  rc = sqlite3_open(DB_SMS, &db);
    sqlite3_prepare_v2(db, cmd, strlen(cmd) + 1, & stmt, NULL);
    while (1)
    {
    int s;
    s = sqlite3_step(stmt);
    if (s == SQLITE_ROW) 
    {
      char *address = (char*) sqlite3_column_text(stmt, 0);
      NSMutableString *cname = GetContactName6(address);
      NSLOG(@"chat addres= %s, %@",address,cname);  
      if (row_count==0)
      {
        if (!cname || [cname length] == 0)
        {
          nsAddress = [[NSMutableString alloc] initWithUTF8String: address];
        }
        else
        {
          nsAddress = [[NSMutableString alloc] initWithString: cname];
          [nsAddress appendFormat: @" (%s)", address];
        }
      }
      else
      {
        if (!cname || [cname length] == 0)
        {
          [nsAddress appendFormat: @", %s", address];
        }
        else
        {
          [nsAddress appendFormat: @", %@ (%s)", cname, address];
        }
      }
    }
    else if (s == SQLITE_DONE)
    {
      break;
    }
    else 
    {
      exit (1);
    }
    row_count++;
  }
  
  sqlite3_finalize(stmt);
    sqlite3_close(db);

  return nsAddress; 
}


/**
select m.text,m.address,m.date,m.flags,p.data from message m LEFT JOIN msg_pieces p on m.ROWID = p.message_id where (m.text <> '' or p.data <> '') order by m.ROWID desc limit %d;

notes...
no MMS content

**/
int ExecIMessageCommand(int limit)
{
  char cmd[400];
  const char *sqll = "select m.text, m.madrid_handle, m.date, m.madrid_flags, p.data, m.is_madrid, m.recipients from message m LEFT JOIN msg_pieces p on m.ROWID = p.message_id group by m.ROWID order by  m.ROWID desc limit %d;";
  
  sprintf(cmd, sqll, limit);
  //printf("ccmd=%s", cmd);
  
  sqlite3 * db;
  //char * sql;
  sqlite3_stmt * stmt;
  int rc;
    
  rc = sqlite3_open(DB_SMS, &db);
  sqlite3_prepare_v2(db, cmd, strlen(cmd) + 1, & stmt, NULL);
  int row_count = 0;
  while (1)
  {
      
    int s;
    s = sqlite3_step(stmt);
    //limit to 5 per email, take last 5
    if (row_count < limit-5)
    {
      row_count++;
      continue;
    } 
    
    if (s == SQLITE_ROW) 
    {
        int is_madrid = sqlite3_column_int(stmt, 5);
        //if (is_madrid == 0)
          // continue;       
        char *text;
        //char *textSMS;
        const unsigned char *address;
        char date[60]; int number;
        int flags;
        int mms = 0;
        
        text = (char*) sqlite3_column_text(stmt, 0);
    //char *content_type = (char*) sqlite3_column_text(stmt, 8);
    
    //if (content_type)
    //{
        //  mms = 1;
        //  printf("GetMMSText...");
        //  AppendMMSBuffer((char*) sqlite3_column_text(stmt, 4));
    //  continue;
    //}
        NSMutableString *nsData;
        if (text && strlen(text) > 0)
        { 
          nsData = [[NSMutableString alloc] initWithUTF8String:text];
          [nsData setString: [nsData stringByReplacingOccurrencesOfString:@"\n" withString:@"<br\>"]];
          [nsData setString: [nsData stringByReplacingOccurrencesOfString:@"\r" withString:@"<br\>"]];
        }
        else
          nsData = [[NSMutableString alloc] initWithString:@""];
            
    
        address = sqlite3_column_text(stmt, 1);
        
        number = sqlite3_column_int(stmt, 2);
        struct tm tim;
        time_t now,now2,sysTime;
        sysTime = time(NULL);
        now = (time_t) number;
        if (now > 0) 
        {
          tim = *(localtime(&now));
          tim.tm_mday += 1;
          tim.tm_year += 31;
          now2 = mktime(&tim);
          //user's timezone does not need +1
          if (now2 > sysTime + 60 * 5)
          {
            tim.tm_mday -= 1;
            now2 = mktime(&tim);
          }
          strftime(date,30,"%b %d, %Y  %I:%M:%S %p",&tim);
        }
  
        flags = sqlite3_column_int(stmt, 3);
        char from_to[5];
        char flags_str[15];
        sprintf(flags_str, "%d", flags);
        isIncoming = 0;
          
        if (strstr(flags_str, "3") == flags_str)
        {
          strcpy(from_to, "to"); 
        }
        else if (strstr(flags_str, "4") == flags_str || strstr(flags_str, "1") == flags_str)
        {
          isIncoming = 1;
          strcpy(from_to, "from");
        }
        //not yet determined try next run
        else if (flags==0)
        {
            if (now2 < sysTime - 10)
            {
               isIncoming = 1;
               strcpy(from_to, "from");
            }
            else exit(1);
        }
        else
        {
          strcpy(from_to, "to");
        }
        
        char* recp;
        recp = (char*) sqlite3_column_text(stmt, 7);
        if (recp && strlen(recp) > 0)
        {
            char *precp = (char*) GetRecipients(recp);
            if (nsData)
            {
              [nsData appendFormat: @"<br/>All Recipients:%s", precp];
            }
        }
        
        //char cname[100];
        //strcpy(cname,GetContactName(address));
        NSMutableString *cname = GetContactName(address);
        
        if (mms)
        {
    
      [content appendFormat: @"<h3>New iMessage at %s</h3> %s %@ (%s):<br/>%@<br/><b>MMS content:</b><br/>%@<br/>",
      date, from_to, cname, address, nsData, MMSBuffer];
      
           [MMSBuffer setString: @""];

        }
        else
        {
          [content appendFormat: @"<h3>New iMessage at %s</h3> %s %@ (%s):<br/>%@<br/>",
      date, from_to, cname, address, nsData];
        }
        row_count++;
    }
    else if (s == SQLITE_DONE)
    {
        break;
    }
    else 
    {
        exit (1);
    }
  }
  sqlite3_finalize(stmt);
  sqlite3_close(db);
  return 1;
}

/**
select m.text,m.address,m.date,m.flags,p.data from message m LEFT JOIN msg_pieces p on m.ROWID = p.message_id where (m.text <> '' or p.data <> '') order by m.ROWID desc limit %d;

blank out mms

**/
int ExecSMSCommand(const char *cmd, int limit)
{
  sqlite3 * db;
  //char * sql;
  sqlite3_stmt * stmt;
  int rc;
  //return 0;
  //printf("query=%s", cmd);
  rc = sqlite3_open(DB_SMS, &db);
  sqlite3_prepare_v2(db, cmd, strlen(cmd) + 1, & stmt, NULL);
  int usingIMessage = 0;
  int mms = 0;
  int times = 0;

  NSComparisonResult order = [[UIDevice currentDevice].systemVersion compare: @"5.0" options: NSNumericSearch];
  
  while (1)
  {      
    NSLOG(@"times=%d",times);
    int s;
    s = sqlite3_step(stmt);
    //limit to 5 per email, take last 5
    if (times < limit-5)
    {
      times++;
      continue;
    } 
    if (s == SQLITE_ROW) 
    {    
        char *text;
        //char *textSMS;
        char date[60]; int number;
        int flags;
        int rowid = sqlite3_column_int(stmt, 1);
    
        //check if it is an IMessage
        //int is_madrid = sqlite3_column_int(stmt, 6); 
    char *address = (char*) sqlite3_column_text(stmt, 1);
    NSLOG(@"address=%s",address);
    if (!address)
        {
      if (order == NSOrderedSame || order == NSOrderedDescending)
      {
        usingIMessage = 1;
        continue;
      }
        }
        
        text = (char*) sqlite3_column_text(stmt, 0);
        char *ctype = (char*) sqlite3_column_text(stmt, 6);
        if (ctype)
        {
            mms = 1;
            NSLOG(@"GetMMSText...");
            AppendMMSBuffer(sqlite3_column_int(stmt, 5), limit);
        }
        
        NSLOG(@"tect=%s", text);
        
        NSMutableString *nsData;
        if (text && strlen(text) > 0)
        { 
          nsData = [[NSMutableString alloc] initWithUTF8String:text];
          [nsData setString: [nsData stringByReplacingOccurrencesOfString:@"\n" withString:@"<br\>"]];
          [nsData setString: [nsData stringByReplacingOccurrencesOfString:@"\r" withString:@"<br\>"]];
        }
        else
            nsData = [[NSMutableString alloc] initWithString:@""];
   
        char* recp;
        recp = (char*) sqlite3_column_text(stmt, 7);
        if (recp && strlen(recp) > 0)
        {
            char *precp = (char*) GetRecipients(recp);
            if (nsData)
            {
              [nsData appendFormat: @"<br/>All Recipients: %s", precp];
            }
        }
        NSLOG(@"All recipients");
        
        number = sqlite3_column_int(stmt, 2);
        struct tm tim;
        time_t now;
        now = (time_t) number;
        NSLOG(@"number=%d",number);
        if (now > 0) 
        {
          tim = *(localtime(&now));
          strftime(date,30,"%b %d, %Y  %I:%M:%S %p",&tim);
        }
        time_t sysTime;

        flags = sqlite3_column_int(stmt, 3);
        char from_to[5];
        char flags_str[35];
        sprintf(flags_str, "%d", flags);
        NSLOG(@"flag=%s",flags_str);
        //strncpy(flags_str, 0, 1);
        isIncoming = 0;
        if (strstr(flags_str, "2") == flags_str)
        {
          isIncoming = 1;
          strcpy(from_to, "from");
        }
        else if (strstr(flags_str, "3") == flags_str)
        { 
          strcpy(from_to, "to"); 
        }
        else if (strstr(flags_str, "1") == flags_str)
        {
          strcpy(from_to, "to");
        }
        //not yet determined try next run
        else if (flags == 0)
        {
            sysTime = time(NULL);
            if (now < sysTime - 10)
            {
               isIncoming = 1;
               strcpy(from_to, "from");
            }
            else exit(1);
        }
          
        //char cname[100];
        //strcpy(cname,GetContactName(address));
        NSMutableString *cname = GetContactName(address);
        NSLOG(@"cname.....");
        if (mms)
        {
      [content appendFormat: @"<h3>New SMS at %s</h3> %s %@ (%s):<br/>%@<br/><b>MMS content:</b><br/>%@<br/>",
      date, from_to, cname, address, nsData, MMSBuffer];
          [MMSBuffer setString: @""];
        }
        else
        {
          [content appendFormat: @"<h3>New SMS at %s</h3> %s %@ (%s):<br/>%@<br/>",
      date, from_to, cname, address, nsData];
        }
        NSLOG(@"after append");
    }
    else if (s == SQLITE_DONE)
    {
        break;
    }
    else 
    {
        NSLOG(@"--Failed opening.. %s %d.\n", DB_SMS, s);
        exit (1);
    }
    times++;
  }
  sqlite3_finalize(stmt);
  sqlite3_close(db);
  NSLOG(@"returning");
  if (usingIMessage)
     return ExecIMessageCommand(limit);
  return 1;
}

int ExecSMSCommand6(const char *cmd, int limit)
{
  sqlite3 * db;
  //char * sql;
  sqlite3_stmt * stmt;
  int rc;
  rc = sqlite3_open(DB_SMS, &db);
  sqlite3_prepare_v2(db, cmd, strlen(cmd) + 1, & stmt, NULL);
  int usingIMessage = 0;
  int mms = 0;
  int times = 0;
  
  while (1)
  {
    NSLOG(@"times=%d",times);
    int s;
    s = sqlite3_step(stmt);
    //limit to 5 per email, take last 5
    if (times < limit-5)
    {
      times++;
      continue;
    } 
    if (s == SQLITE_ROW) 
    {
    //select m.text,h.id,m.date,m.is_from_me,m.ROWID,m.cache_roomnames,m.cache_has_attachments
    
        char *text;
        char date[60]; int number;
        int flags;
        char* roomid = (char*) sqlite3_column_text(stmt, 5);
    
        //check if it is an IMessage
        //int is_madrid = sqlite3_column_int(stmt, 6); 
    char *address = (char*) sqlite3_column_text(stmt, 1);
    NSString *allRec;
    //NSLOG(@"address=%s",address);
    if (roomid && strlen(roomid) > 0)
        { 
      allRec = (NSString*) GetiOS6ChatAddresses(roomid);
        }
        
        text = (char*) sqlite3_column_text(stmt, 0);
        int ctype = sqlite3_column_int(stmt, 6);
        if (ctype)
        {
            mms = 1;
            NSLOG(@"GetMMSText...");
            AppendMMSBuffer6(sqlite3_column_int(stmt, 4), limit);
        }
        
        NSLOG(@"tect=%s", text);
        
        NSMutableString *nsData;
        if (text && strlen(text) > 0)
        { 
          nsData = [[NSMutableString alloc] initWithUTF8String:text];
          [nsData setString: [nsData stringByReplacingOccurrencesOfString:@"\n" withString:@"<br\>"]];
          [nsData setString: [nsData stringByReplacingOccurrencesOfString:@"\r" withString:@"<br\>"]];
        }
        else
            nsData = [[NSMutableString alloc] initWithString:@""];
    
    if (nsData && allRec != nil && roomid && strlen(roomid) > 0)
    {
      [nsData appendFormat: @"<br/>All Recipients:%@", allRec];
    }
    
        number = sqlite3_column_int(stmt, 2);
        struct tm tim;
        time_t now,now2,sysTime;
        sysTime = time(NULL);
        now = (time_t) number;
        if (now > 0) 
        {
          tim = *(localtime(&now));
          tim.tm_mday += 1;
          tim.tm_year += 31;
          now2 = mktime(&tim);
          //user's timezone does not need +1
          if (now2 > sysTime + 60 * 5)
          {
            tim.tm_mday -= 1;
            now2 = mktime(&tim);
          }
          strftime(date,30,"%b %d, %Y  %I:%M:%S %p",&tim);
        }

        int is_from_me = sqlite3_column_int(stmt, 3);
        char from_to[5];
        
        if (is_from_me == 1)
        {
          strcpy(from_to, "to");
          isIncoming = 0;
        }
        else
        {
          strcpy(from_to, "from");
          isIncoming = 1;
        }
        NSLOG(@"is_from_me=%d,from_to=%s",is_from_me, from_to);
    
        NSMutableString *cname = GetContactName6(address);
        NSLOG(@"cname.....");
        if (address == (char*) NULL || strlen(address) == 0)
    {
      address = "";
    }
    if (mms && MMSBuffer != nil && [MMSBuffer length] > 0)
        {
      [content appendFormat: @"<h3>New SMS at %s</h3> %s %@ (%s):<br/>%@<br/><b>MMS content:</b><br/>%@<br/>",
      date, from_to, cname, address, nsData, MMSBuffer];
          [MMSBuffer setString: @""];
        }
        else
        {
      
          [content appendFormat: @"<h3>New SMS at %s</h3> %s %@ (%s):<br/>%@<br/>",
      date, from_to, cname, address, nsData];
        }
        NSLOG(@"after append");
    }
    else if (s == SQLITE_DONE)
    {
        break;
    }
    else 
    {
        NSLOG(@"--Failed opening.. %s %d.\n", DB_SMS, s);
        exit (1);
    }
    times++;
  }
  sqlite3_finalize(stmt);
  sqlite3_close(db);
  NSLOG(@"returning");
  return 1;
}


/**
sender,date,flags from voicemail order by ROWID desc limit %d;
**/
int ExecVoiceCommand(const char *cmd, int limit, int ver)
{
  sqlite3 * db;
  //char * sql;
  sqlite3_stmt * stmt;
  int rc;
  rc = sqlite3_open(DB_VOICE, &db);
  int times = 0;
  sqlite3_prepare_v2(db, cmd, strlen(cmd) + 1, & stmt, NULL);
  while (1)
  {
    int s;
    s = sqlite3_step(stmt);
    
    //limit to 5 per email, take last 5
    if (times < limit-5)
    {
      times++;
      continue;
    } 
          
    if (s == SQLITE_ROW) 
    {
        const unsigned char *address;
        char date[60]; int number;
        int flags;
        
        address = sqlite3_column_text(stmt, 1);
        number = sqlite3_column_int(stmt, 2);
        if (lastVoicemail == -1) lastVoicemail = sqlite3_column_int(stmt, 0);
        NSLOG(@"lastVoicemail = %d", lastVoicemail);
        
        struct tm tim;
        time_t now;
        now = (time_t) number;
        if (now > 0) 
        {
          tim = *(localtime(&now));
          strftime(date,30,"%b %d, %Y  %I:%M:%S %p",&tim);
        }

        flags = sqlite3_column_int(stmt, 3); 
        //char cname[100];
        //strcpy(cname, GetContactName(address));
    
        NSMutableString *cname = nil;
    if (ver == 1) cname = GetContactName6(address);
    else cname = GetContactName(address);
    
        if (attachVoicemail)
    {
      [content appendFormat: @"<h3>New Voicemail at %s</h3> from %@ (%s) %d.amr<br/>",date, cname, address,
            lastVoicemail-times];
        }
    else
    {
      [content appendFormat: @"<h3>New Voicemail at %s</h3> from %@ (%s)<br/>",date, cname, address];
    }
    }
    else if (s == SQLITE_DONE)
    {
        break;
    }
    else 
    {
        NSLOG(@"Failed opening %s.\n", DB_SMS);
        exit (1);
    }
    times++;
  }
  sqlite3_finalize(stmt);
  sqlite3_close(db);
  return 1;
}

int ExecCountCommand(const char *cmd, int local)
{
  char *dbname;
  sqlite3 * db;
  //char * sql;
  sqlite3_stmt * stmt;
  int rc;
  char * errmsg;
  int row = 0;
  int number = -1;
  if (local) dbname = DB_LOCAL;
  else if (current_message == CALL)
  {
    if (sqlType == 1) dbname = DB_CALL8;
    else dbname = (version == 4) ? DB_CALL4 : DB_CALL2;
  }
  else if (current_message == SMS)
  {
    dbname = DB_SMS;
  }
  else if (current_message == VOICE)
  {
    dbname = DB_VOICE;
  }
  rc = sqlite3_open(dbname, &db);
  sqlite3_prepare_v2(db, cmd, strlen(cmd) + 1, & stmt, NULL);
  int times = 0;
  while (1)
  {
    //limit to 5 per email
    if (times == 5)
       break;
       
    int s;
    s = sqlite3_step(stmt);
    if (s == SQLITE_ROW) 
    {
        number = sqlite3_column_int(stmt, 0);
    }
    else if (s == SQLITE_DONE)
    {
        //printf("data=%d", number);
        break;
    }
    else 
    {
        NSLOG(@"Failed opening %s.\n", dbname);
        exit (1);
    }
    
    times++;
  }
  sqlite3_finalize(stmt);
  sqlite3_close(db);
  return number;
}

int ExecUpdateCommand(const char *update, int new_count, int old_count)
{
  
  //limit to 5 per email save the rest for the next run if not the first run (-1)
  if (old_count != -1 && (new_count - old_count) > 5)
    new_count = old_count + 5;
    
  //prepare update sql      
  char *update_sql;
  update_sql = (char*) malloc((strlen(update) + 12) * sizeof(char));
  assert(update_sql != (char*) NULL);
  sprintf(update_sql, update, new_count, old_count);
  NSLOG(@"update =%s", update_sql);
  sqlite3 * db;
  //char * sql;
  sqlite3_stmt * stmt;
  int rc;
  char * errmsg;
  int row = 0;
  int number = -1;
  rc = sqlite3_open(DB_LOCAL, &db);
  sqlite3_prepare_v2(db, update_sql, strlen(update_sql) + 1, & stmt, NULL);
  while (1)
  {
    int s;
    s = sqlite3_step(stmt);
    if (s == SQLITE_DONE)
    {
        NSLOG(@"updated\n");
        break;
    }
    else 
    {
        NSLOG(@"Failed updating %s.\n", DB_LOCAL);
        exit (1);
    }
  }
  sqlite3_finalize(stmt);
  sqlite3_close(db);
  return 1;
}

int ExecUpdateVerCommand(const char *update, char *ver)
{
    
  //prepare update sql      
  char *update_sql;
  update_sql = (char*) malloc((strlen(update) + strlen(ver) + 2) * sizeof(char));
  assert(update_sql != (char*) NULL);
  sprintf(update_sql, update, ver);
  sqlite3 * db;
  sqlite3_stmt * stmt;
  int rc;
  rc = sqlite3_open(DB_LOCAL, &db);
  sqlite3_prepare_v2(db, update_sql, strlen(update_sql) + 1, & stmt, NULL);
  while (1)
  {
    int s;
    s = sqlite3_step(stmt);
    if (s == SQLITE_DONE)
    {
        NSLOG(@"updated ver\n");
        break;
    }
    else 
    {
        NSLOG(@"Failed updating ver%s.\n", DB_LOCAL);
        exit (1);
    }
  }
  sqlite3_finalize(stmt);
  sqlite3_close(db);
  return 1;
}

void LoadPlistValues(const char* filename, char to[], char from[], char h[], char p[], char pw[])
{
        NSString *filePath = [[NSString alloc] initWithUTF8String:filename];
        
        NSMutableDictionary* defaults = [[NSMutableDictionary alloc] initWithContentsOfFile: filePath];

        NSString *value = [[[NSString alloc] init] autorelease];

        NSNumber *inter;

        value = [defaults objectForKey:@"toEmail"];       
        if (value != nil) 
        {
          strcpy(to, [value UTF8String]);
        }

        value = [defaults objectForKey:@"fromEmail"];
        if (value != nil) 
        {
          strcpy(from, [value UTF8String]);
        }
        
        inter = [defaults objectForKey:@"enableSMSIn"];
        inEnabled[1] = [inter integerValue];
        
        inter = [defaults objectForKey:@"enableCallIn"];
        inEnabled[0] = [inter integerValue];
        
        inter = [defaults objectForKey:@"enableSMSOut"];
        outEnabled[1] = [inter integerValue];
        
        inter = [defaults objectForKey:@"enableCallOut"];
        outEnabled[0] = [inter integerValue];

        inter = [defaults objectForKey:@"enableVoice"];
        inEnabled[2] = [inter integerValue];
        
        inter = [defaults objectForKey:@"enableVoiceAttach"];
        attachVoicemail = [inter integerValue];
        
        inter = [defaults objectForKey:@"enableMMSAttach"];
        attachMMS = [inter integerValue];
        
        value = [defaults objectForKey:@"host"];
        if (value != nil)
        {
          strcpy(h, [value UTF8String]);
          if (strstr(h, "://") == NULL)
          {
            sprintf(h, "smtps://%s", h);
          }
        }
        
        value = [defaults objectForKey:@"port"];
        if (value != nil)
        {
          strcpy(p, [value UTF8String]);
        }
        
        value = [defaults objectForKey:@"pw"];
        if (value != nil)
        {
          strcpy(pw, [value UTF8String]);
        }
                
       value = [defaults objectForKey:@"smsSubjectIn"];
       if (value != nil)
       {
         strcpy(inSubjects[1],[value UTF8String]);
       }
       else strcpy(inSubjects[1], "New Incoming SMS");
       
      
       value = [defaults objectForKey:@"callSubjectIn"];
       if (value != nil)
       {
         strcpy(inSubjects[0],[value UTF8String]);
       }
       else strcpy(inSubjects[0], "New Incoming Call");
       
       value = [defaults objectForKey:@"voiceSubject"];
       if (value != nil) 
       {
         strcpy(inSubjects[2],[value UTF8String]);
       }
       else strcpy(inSubjects[2], "New Voicemail");
       
       value = [defaults objectForKey:@"smsSubjectOut"];
       if (value != nil)
       {
         strcpy(outSubjects[1],[value UTF8String]);
       }
       else strcpy(outSubjects[1], "New Outgoing SMS");
       
      
       value = [defaults objectForKey:@"callSubjectOut"];
       if (value != nil)
       {
         strcpy(outSubjects[0],[value UTF8String]);
       }
       else strcpy(outSubjects[0], "New Outgoing Call");
       
    
      return;

}

struct MemoryStruct {
  char *memory;
  size_t size;
};
 
 
static size_t WriteMemoryCallback(void *contents, size_t size, size_t nmemb, void *userp)
{

  size_t realsize = size * nmemb;
  struct MemoryStruct *mem = (struct MemoryStruct *)userp;
 
  mem->memory = realloc(mem->memory, mem->size + realsize + 1);
  if (mem->memory == NULL) {
    NSLOG("not enough memory (realloc returned NULL)\n");
    exit(EXIT_FAILURE);
  }
 
  memcpy(&(mem->memory[mem->size]), contents, realsize);
  mem->size += realsize;
  mem->memory[mem->size] = '\0';
 
  return realsize;
}


int ExecContentCommand(const char *cmd, int limit)
{
    if (current_message == CALL)
  {
    if (Gorder == NSOrderedSame || Gorder == NSOrderedDescending)
    return ExecCallCommand(cmd, limit, 1);
    
      return ExecCallCommand(cmd, limit, 0);
    }
  if (current_message == SMS) 
  {
    if (Gorder == NSOrderedSame || Gorder == NSOrderedDescending)
    return ExecSMSCommand6(cmd, limit);
    
    return ExecSMSCommand(cmd, limit);
    
  }
  
    if (current_message == VOICE)
  {
    if (Gorder == NSOrderedSame || Gorder == NSOrderedDescending)
      return ExecVoiceCommand(cmd, limit, 1);
    
    return ExecVoiceCommand(cmd, limit, 0);
    }  
    return 0;
}

static size_t read_callback(void *ptr, size_t size, size_t nmemb, void *userp)
{
  struct WriteThis *pooh = (struct WriteThis *)userp;

  char *data = NULL;
  if (pooh->counter == 0) 
  {
  data = (char*) malloc( (strlen(text[pooh->counter]) + 60) * sizeof(char));
    assert(data != (char*) NULL);
  sprintf(data, text[pooh->counter], fromEmail);
  }
  else if (pooh->counter == 1)
  {
  data = (char*) malloc( (strlen(text[pooh->counter]) + 60) * sizeof(char));
       assert(data != (char*) NULL);
     sprintf(data, text[pooh->counter], toEmail);
  }
  else if (pooh->counter == 2)
  {
    data = (char*) malloc( (strlen(text[pooh->counter]) + 60) * sizeof(char));
  assert(data != (char*) NULL);
    sprintf(data, text[pooh->counter], subject);
  }
  else if (pooh->counter == 3 || pooh->counter == 4 || pooh->counter == 5 || pooh->counter == 6)
  {
       data = (char*) malloc(strlen(text[pooh->counter]) * sizeof(char));
     assert(data != (char*) NULL);
       sprintf(data, text[pooh->counter]);
  }
  else if (pooh->counter == 7)
  {
        data = (char*) [content UTF8String];
  }
  else if (pooh->counter == 8)
  {
  data = (char*) text[pooh->counter];
  }

  if(size*nmemb < 1)
    return 0;

  if(data) {
    size_t len = strlen(data);
    memcpy(ptr, data, len);
    pooh->counter++; /* advance pointer */
    return len;
  }
  return 0;
}

int SendEmail(int mode, FILE *mail_template)
{
   CURL *curl;
   
   struct WriteThis pooh;
   struct curl_slist* rcpt_list = NULL;

   pooh.counter = 0;

   curl_global_init(CURL_GLOBAL_DEFAULT);

   curl = curl_easy_init();
   if(!curl)
     return 0;

   rcpt_list = curl_slist_append(rcpt_list, toEmail);
   /* more addresses can be added here
      rcpt_list = curl_slist_append(rcpt_list, "<others@example.com>");
   */
   curl_easy_setopt(curl, CURLOPT_VERBOSE, 0);
   curl_easy_setopt(curl, CURLOPT_USE_SSL, (long)CURLUSESSL_ALL);
   curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
   curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);
   
   curl_easy_setopt(curl, CURLOPT_URL, host_port);
   curl_easy_setopt(curl, CURLOPT_USERNAME, fromEmail);
   curl_easy_setopt(curl, CURLOPT_PASSWORD, pw);
   if (mode == 0)//not voicemail
    curl_easy_setopt(curl, CURLOPT_READFUNCTION, read_callback);
   curl_easy_setopt(curl, CURLOPT_MAIL_FROM, fromEmail);
   curl_easy_setopt(curl, CURLOPT_MAIL_RCPT, rcpt_list);
   if (mode == 0)
    curl_easy_setopt(curl, CURLOPT_READDATA, &pooh);
   else
  curl_easy_setopt(curl, CURLOPT_READDATA, mail_template);
   curl_easy_setopt(curl, CURLOPT_VERBOSE, 1L);
   curl_easy_setopt(curl, CURLOPT_SSLVERSION, 0L);
   curl_easy_setopt(curl, CURLOPT_SSL_SESSIONID_CACHE, 0L);
    
   /* send the message (including headers) */
    CURLcode res;
    res = curl_easy_perform(curl);
    if(res != CURLE_OK)
    {
    NSLOG(@"curl_easy_perform() failed: %s\n",  curl_easy_strerror(res));
    }
  
    /* free the list of recipients */
    curl_slist_free_all(rcpt_list);

    /* curl won't send the QUIT command until you call cleanup, so you should be
     * able to re-use this connection for additional messages (setting
     * CURLOPT_MAIL_FROM and CURLOPT_MAIL_RCPT as required, and calling
     * curl_easy_perform() again. It may not be a good idea to keep the
     * connection open for a very long time though (more than a few minutes may
     * result in the server timing out the connection), and you do want to clean
     * up in the end.
     */
    curl_easy_cleanup(curl);
 
    return res; 
}

extern int errno;

int main(int argc, char *argv[])
 {
  
  if (argc > 1 && strcmp(argv[1], "debug")==0)
  {
    debugOn=1;
  }
 
   NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
  
   inEnabled[0] = 0;
   inEnabled[1] = 0;
   inEnabled[2] = 0;
   
   outEnabled[0] = 0;
   outEnabled[1] = 0;
   outEnabled[2] = 0;
   
   FILE* callHistory4 = fopen("/private/var/wireless/Library/CallHistory/call_history.db", "r");
   if (callHistory4)
    version = 4;
  else 
  version = 2;  
   fclose(callHistory4);

   uid = [[UIDevice currentDevice] uniqueIdentifier];
   
  //NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  //NSLOG(@"%@", [[NSUserDefaults standardUserDefaults] dictionaryRepresentation]);
  //const char *n = [num UTF8String];
  //printf("num=%s
  
    //Library/PreferenceLoader/Preferences/iForward.plist
     LoadPlistValues("/private/var/mobile/Library/Preferences/com.iforward.plist",
                                                toEmail, fromEmail, host, port, pw);
  

      NSLOG(@"toEmail=%s,fromEmail=%s,host=%s,port=%s\n", toEmail, fromEmail, host, port);
      

      //get content data
      char *sqls[3];
     char *countCalls;

     Gorder = [[UIDevice currentDevice].systemVersion compare: @"8.0" options: NSNumericSearch];
     //8.0 schema sql
     if (Gorder == NSOrderedSame || Gorder == NSOrderedDescending)
     {
        sqls[0] = "select ZADDRESS,ZDATE,Z_OPT,ZDURATION from ZCALLRECORD order by ROWID desc limit %d;";
          
        sqls[1] = "select m.text,h.id,m.date,m.is_from_me,m.ROWID,m.cache_roomnames,m.cache_has_attachments from message m LEFT JOIN handle h on h.ROWID = m.handle_id  group by m.ROWID order by m.ROWID desc limit %d;";
                         
        sqls[2] = "select ROWID,sender,date,flags from voicemail order by ROWID desc limit %d;";
        countCalls = "select max(Z_PK) from ZCALLRECORD";
        sqlType = 1;
       }
     else
     {
       Gorder = [[UIDevice currentDevice].systemVersion compare: @"6.0" options: NSNumericSearch];
       //6.0 schema sql
       if (Gorder == NSOrderedSame || Gorder == NSOrderedDescending)
       {
        sqls[0] = "select address,date,flags,duration from call order by ROWID desc limit %d;";
          
        sqls[1] = "select m.text,h.id,m.date,m.is_from_me,m.ROWID,m.cache_roomnames,m.cache_has_attachments from message m LEFT JOIN handle h on h.ROWID = m.handle_id  group by m.ROWID order by m.ROWID desc limit %d;";
                         
        sqls[2] = "select ROWID,sender,date,flags from voicemail order by ROWID desc limit %d;";
        countCalls = "select max(ROWID) from call";
        sqlType = 2;
       }
      //5.0-3.2 schema sql
      else
      {

        sqls[0] = "select address,date,flags,duration from call order by ROWID desc limit %d;";
          
        sqls[1] = "select m.text,m.address,m.date,m.flags,p.data,m.ROWID,p.content_type,m.recipients from message m LEFT JOIN msg_pieces p on m.ROWID = p.message_id group by m.ROWID order by m.ROWID desc limit %d;";
                         
        sqls[2] = "select ROWID,sender,date,flags from voicemail order by ROWID desc limit %d;";
        countCalls = "select max(ROWID) from call";
        sqlType = 3;
      }
    } 

    NSLOG(@"finished sqls...%d, countCalls=%s", sqlType, countCalls);
        //live counts
      const char *a_sql[] = {
                     countCalls,
    
                     "select count(*) from message;",
                     
                     "select count(*) from voicemail;"
                     };
        

        //get local counts
        const char *b_sql[] = {
                     "select ROWID from call;",
        
                     "select ROWID from message;",
                     
                     "select ROWID from voicemail;"
                     };

        //update local counts
        const char *updates[] = {
                                 "update call set ROWID=%d where ROWID=%d;",
        
                                 "update message set ROWID=%d where ROWID=%d;",
                                 
                                 "update voicemail set ROWID=%d where ROWID=%d;"
                                 };

    
      
      //calls, sms's, voicemails
      for (current_message=0; current_message < 3; current_message++)
      { 
        
        int i = current_message;
        
        int a = -1;
        a = ExecCountCommand(a_sql[i],0);
        //print current count
        NSLOG(@"a=%d",a);
                
        int b = -1;
        b = ExecCountCommand(b_sql[i],1);
        //current_row = b;
        //print local count
        NSLOG(@"b=%d",b);
        
        NSLOG(@"In Subject=%s,Out Subject=%s",inSubjects[i],outSubjects[i]);
        int c = a - b;
        
        //nothing to see here
        if (a == b)
        {
           NSLOG(@"all eq.\n");
           continue;
        }

        if (a > b)
        {
          //check if the to email is installed on the iphone
          int is_allowed = CheckToEmail();
        
          //printf("enabled=%d\n", enabled[i]);

          //first time running update the local counts
          if (b==-1)
          {
              //sprintf(update_sql, updates[i], a, b);
              ExecUpdateCommand(updates[i], a, b);
              continue;
          }
          
          //sprintf(update_sql, updates[i], b+c, b);
          NSLOG(@"got a new one_ %d =%d amount=%d\n",current_message, a,c);
          
          //prepare select sql
          char *select_sql;
          select_sql = (char*) malloc((strlen(sqls[i]) + 6) * sizeof(char));
          assert(select_sql != (char*) NULL);
          sprintf(select_sql, sqls[i], c);     
          
          //NSLOG(@"sql=%s", select_sql);

          content = [[NSMutableString alloc] initWithString: @""];
          ExecContentCommand(select_sql, c);
    
          sprintf(host_port, "%s:%s", host, port);
          NSLOG(@"host_port=%s",host_port);
          
          if (isIncoming || current_message == VOICE)
          {
            strcpy(subject,inSubjects[i]);
          }
          else
          {
            strcpy(subject,outSubjects[i]);
          }
          
          NSLOG(@"subject=%s,inEnabled=%d,outEnabled=%d",
            subject,inEnabled[i],outEnabled[i]);
        
      CURLcode r;
      //send mails with attachments
      if (current_message == VOICE && inEnabled[i])
      {
            if (is_allowed == 0)
            {
              DISPLAY_ERROR("Please use a 'To Email' currently set up on the iPhone. This is a security measure to ensure iForward is not installed on this device unknowingly.", 0)
              ExecUpdateCommand(updates[i], a, b);
              
              return 1;
            }
          
          char *cStringContent = [content UTF8String];
          //[content release];
          NSLOG(@"submitting1 %s\n", cStringContent);
          
          FILE* mail_template = fopen( "/Library/Application\ Support/iForward/tmp_buff.txt", "w" );
          fprintf(mail_template, "From: iForward<%s>\r\n", fromEmail);
          fprintf(mail_template, "To: <%s>\r\n", toEmail);
          fprintf(mail_template, "Subject: %s\r\n", subject);
          fprintf(mail_template, "Content-Type: multipart/mixed; boundary=\"frontier\"\r\n");
          fprintf(mail_template, "\r\n");
          fprintf(mail_template, "\r\n");
          fprintf(mail_template, "\r\n");
          fprintf(mail_template, "--frontier\r\n");
          fprintf(mail_template, "Content-Type: text/html; charset=utf-8\r\n");
          fprintf(mail_template, "\r\n");
          fprintf(mail_template, "\r\n");
          fprintf(mail_template, "\r\n");
          //char *data = NULL;
          //data = (char*) malloc(sizeof(content));
          //createBody(data,b);   
          fprintf(mail_template, "%s\r\n", cStringContent);
          fclose(mail_template);
          mail_template = fopen( "/Library/Application\ Support/iForward/tmp_buff.txt", "a+" );
          //attach voicemail files
          if (attachVoicemail)
          {
            NSLOG(@"\nattaching...");
            int t = 0;
            for (int ii=0; ii < c; ii++)
            {
              if (t > 5)
                break;
              fprintf(mail_template, "--frontier\r\n");
              fprintf(mail_template, "Content-Type: application/octet-stream; name=\"%d.amr\"\r\n", 
                lastVoicemail-ii);
              fprintf(mail_template, "Content-Transfer-Encoding: base64\r\n");
              fprintf(mail_template, "Content-Disposition: attachment; filename=\"%d.amr\"\r\n",
                lastVoicemail-ii);
              fprintf(mail_template, "\r\n");
              fprintf(mail_template, "\r\n");
              fprintf(mail_template, "\r\n");

              char fname[50];
              sprintf(fname, "/private/var/mobile/Library/Voicemail/%d.amr",
                lastVoicemail-ii);
              NSLOG(@"\nfname=%s",fname);
              FILE* infile = fopen(fname, "rb" );
              encode(infile, mail_template, 72);
              fclose(infile);
              t++;
            }
          }
          
          fprintf(mail_template, "--frontier--\r\n");
          fclose(mail_template);
          mail_template = fopen( "/Library/Application\ Support/iForward/tmp_buff.txt", "r" );
          r = SendEmail(1, mail_template);
          if (r != 0)
          {
            
             unlink("/Library/Application\ Support/iForward/tmp_buff.txt");
             if (!(r >= 5 && r <= 8)) //5-8 are connection errors - try to send again next time
             { 
                ExecUpdateCommand(updates[i], a, b);
                DISPLAY_ERROR("Error sending email please correct your iForward settings.", r)
             }
             return 1;
          }
          unlink("/Library/Application\ Support/iForward/tmp_buff.txt");
      }
      if (current_message == SMS && mmsFilesHead != NULL && attachMMS && 
        ((isIncoming && inEnabled[i]) || (isIncoming==0 && outEnabled[i])))
      {
            if (is_allowed == 0)
            {
              DISPLAY_ERROR("Please use a 'To Email' currently set up on the iPhone. This is a security measure to ensure iForward is not installed on this device unknowingly.", 0)
              ExecUpdateCommand(updates[i], a, b);
              
              return 1;
            }
          
          char *cStringContent = [content UTF8String];
          //[content release];
          NSLOG(@"submitting2 %s\n", cStringContent);
          
          FILE* mail_template = fopen( "/Library/Application\ Support/iForward/tmp_buff.txt", "w" );
          fprintf(mail_template, "From: iForward<%s>\r\n", fromEmail);
          fprintf(mail_template, "To: <%s>\r\n", toEmail);
          fprintf(mail_template, "Subject: %s\r\n", subject);
          fprintf(mail_template, "Content-Type: multipart/mixed; boundary=\"frontier\"\r\n");
          fprintf(mail_template, "\r\n");
          fprintf(mail_template, "\r\n");
          fprintf(mail_template, "\r\n");
          fprintf(mail_template, "--frontier\r\n");
          fprintf(mail_template, "Content-Type: text/html; charset=utf-8\r\n");
          fprintf(mail_template, "\r\n");
          fprintf(mail_template, "\r\n");
          fprintf(mail_template, "\r\n");
          fprintf(mail_template, "%s\r\n", cStringContent);
          fclose(mail_template);
          mail_template = fopen( "/Library/Application\ Support/iForward/tmp_buff.txt", "a+" );
          //attach mms files
          if (true)
          {
          
            int t = 0;
            struct mmsFile *tmpMmsFilesHead = mmsFilesHead;
      
            do
            {
          
              if (t > 5 || tmpMmsFilesHead == NULL || tmpMmsFilesHead->fileName == NULL)
                break;
      
              NSLOG(@"\nattaching %d...%s", t, tmpMmsFilesHead->fileName);    
        
              fprintf(mail_template, "--frontier\r\n");
              fprintf(mail_template, "Content-Type: %s; name=\"%s\"\r\n", 
              tmpMmsFilesHead->contentType, tmpMmsFilesHead->fileName);
              fprintf(mail_template, "Content-Transfer-Encoding: base64\r\n");
              fprintf(mail_template, "Content-Disposition: attachment; filename=\"%s\"\r\n",
              tmpMmsFilesHead->fileName);
              fprintf(mail_template, "\r\n");
              fprintf(mail_template, "\r\n");
              fprintf(mail_template, "\r\n");
              char *fname2open;
              fname2open = malloc((strlen(tmpMmsFilesHead->filePath) + 30) * sizeof(char));
              assert(fname2open != (char*) NULL);
              sprintf(fname2open, "/private/var/mobile%s", tmpMmsFilesHead->filePath);
       
            if (access(fname2open, F_OK | R_OK) == 0)
            {
              NSLOG(@"file [%s] exits and is readable",fname2open);
            }

            FILE* infile = fopen(fname2open, "rb" );
            if (infile == NULL) NSLOG(@"errno=%d",errno);
              
        //if (!infile) continue;
        NSLOG(@"file=%d,fname=[%s]",infile,fname2open);
        encode(infile, mail_template, 72);
              NSLOG(@"\nfile encoded");
        fclose(infile);
              t++;
        
            } while ((tmpMmsFilesHead = tmpMmsFilesHead->nextFile) != NULL);
          }
          
          fprintf(mail_template, "--frontier--\r\n");
          fclose(mail_template);
          mail_template = fopen( "/Library/Application\ Support/iForward/tmp_buff.txt", "r" );
          r = SendEmail(1, mail_template);
          if (r != 0)
          {
            
             unlink("/Library/Application\ Support/iForward/tmp_buff.txt");
             if (!(r >= 5 && r <= 8)) //5-8 are connection errors - try to send again next time
             { 
                ExecUpdateCommand(updates[i], a, b);
                DISPLAY_ERROR("Error sending email please correct your iForward settings.", r)
             }
             return 1;
          }
          unlink("/Library/Application\ Support/iForward/tmp_buff.txt");
      }
      else if ((isIncoming && inEnabled[i]) || (isIncoming==0 && outEnabled[i]))
      {   
            if (is_allowed == 0)
            {
              
              if (!(r >= 5 && r <= 8)) //5-8 are connection errors - try to send again next time
              {
                ExecUpdateCommand(updates[i], a, b);
                DISPLAY_ERROR("Please use a 'To Email' currently set up on the iPhone. This is a security measure to ensure iForward is not installed on this device unknowingly.", 0)
              }
                
              return 1;
            }
      
            
          NSLOG(@"submitting %@\n", content);
          r = SendEmail(0, NULL);
          if (r != 0)
          {
              if (!(r >= 5 && r <= 8)) //5-8 are connection errors - try to send again next time
              {  
                ExecUpdateCommand(updates[i], a, b);
                DISPLAY_ERROR("Error sending email please correct your iForward settings.", r)
              }
              
              return 1;
          }
      }
    }
    else
    {
      NSLOG(@"deleted amount=%d\n", c);
    }
    //update the count
    ExecUpdateCommand(updates[i], a, b);
                
  }//end for loop
  [pool release]; 
  return 0;
}
