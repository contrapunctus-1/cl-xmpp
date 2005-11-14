;;;; $Id: cl-xmpp.lisp,v 1.14 2005/11/14 15:14:06 eenge Exp $
;;;; $Source: /project/cl-xmpp/cvsroot/cl-xmpp/cl-xmpp.lisp,v $

;;;; See the LICENSE file for licensing information.

(in-package :xmpp)

(defclass connection ()
  ((server-stream
    :accessor server-stream
    :initarg :server-stream
    :initform nil)
   (server-xstream
    :accessor server-xstream
    :initform nil)
   (stream-id
    :accessor stream-id
    :initarg :stream-id
    :initform nil
    :documentation "Stream ID attribute of the <stream>
element as gotten when we call BEGIN-XML-STREAM.")
   (features
    :accessor features
    :initarg :features
    :initform nil
    :documentation "List of xml-element objects representing
the various features the host at the other end of the connection
supports.")
   (mechanisms
    :accessor mechanisms
    :initarg :mechanisms
    :initform nil
    :documentation "List of xml-element objects representing
the various mechainsms the host at the other end of the connection
will accept.")
   (jid-domain-part
    :accessor jid-domain-part
    :initarg :jid-domain-part
    :initform nil)
   (username
    :accessor username
    :initarg :username)
   (hostname
    :accessor hostname
    :initarg :hostname
    :initform *default-hostname*)
   (port
    :accessor port
    :initarg :port
    :initform *default-port*))
  (:documentation "A TCP connection between this XMPP client and
an, assumed, XMPP compliant server.  The connection does not
know whether or not the XML stream has been initiated nor whether
there may be any reply waiting to be read from the stream.  These
details are left to the programmer."))

(defmethod print-object ((object connection) stream)
  "Print the object for the Lisp reader."
  (print-unreadable-object (object stream :type t :identity t)
    (format stream "to ~A:~A" (hostname object) (port object))
    (if (connectedp object)
	(format stream " (open)")
      (format stream " (closed)"))))

(defun connect (&key (hostname *default-hostname*) (port *default-port*) 
                     (receive-stanzas t) (begin-xml-stream t) jid-domain-part)
  "Open TCP connection to hostname.

By default this will set up the complete XML stream and receive the initial
two stanzas (which would typically be stream:stream and stream:features)
to make sure the connection object is fully loaded with the features,
mechanisms and stream-id.  If this is causing a problem for you just
specify :receive-stanzas nil.

Using the same idea, you can disable the calling to begin-xml-stream.

Some XMPP server's addresses are not the same as the domain part of
the JID (eg. talk.google.com vs gmail.com) so we provide the option of
passing that in here.  Could perhaps be taken care of by the library
but I'm trying not to optimize too early plus if you are going to
do in-band registration (JEP0077) then you don't have a JID until
after you've connected."
  (let* ((stream (trivial-sockets:open-stream
                  hostname port :element-type '(unsigned-byte 8)))
         (connection (make-instance 'connection
                                    :jid-domain-part jid-domain-part
                                    :server-stream stream
                                    :hostname hostname
                                    :port port)))
    (when begin-xml-stream
      (begin-xml-stream connection))
    (when receive-stanzas
      (receive-stanza connection)
      (receive-stanza connection))
    connection))

(defmethod connectedp ((connection connection))
  "Returns t if `connection' is connected to a server and is ready for
input."
  (let ((stream (server-stream connection)))
    (and (streamp stream)
         (open-stream-p stream))))

(defmethod disconnect ((connection connection))
  "Disconnect TCP connection."
  (close (server-stream connection))
  connection)

(defmethod feature-p ((connection connection) feature-name)
  "See if connection has a specific feature.

Eg. (has-feature *my-connection* :starttls)

Returns the xml-element representing the feature if it
is present, nil otherwise."
  (dolist (feature (features connection))
    (when (eq (name feature) feature-name)
      (return-from feature-p feature))))

(defmethod feature-required-p ((connection connection) feature-name)
  "Checks if feature is required.  Three possible outcomes

t - feature is supported and required
nil - feature is support but not required
:not-supported - feature is not supported"
  (let ((feature (feature-p connection feature-name)))
    (if feature
	(if (get-element feature :required)
	    t
	  nil)
      :not-supported)))

(defmethod mechanism-p ((connection connection) mechanism-name)
  (dolist (mechanism (mechanisms connection))
    (let ((name (intern (data (get-element mechanism :\#text)) :keyword)))
      (when (eq name mechanism-name)
	(return-from mechanism-p mechanism)))))

;;
;; Handle
;;

(defmethod handle ((connection connection) (list list))
  (map 'list #'(lambda (x) (handle connection x)) list))

(defmethod handle ((connection connection) object)
  (format *debug-stream* "~&UNHANDLED: ~a~%" object)
  (force-output *debug-stream*)
  object)

;;
;; Produce DOM-ish structure from the XML DOM returned by cxml.
;;

(defmethod parse-result ((connection connection) (objects list))
  (map 'list #'(lambda (x) (parse-result connection x)) objects))

(defmethod parse-result ((connection connection) (document dom-impl::document))
  (let (objects)
    (dom:map-node-list #'(lambda (node)
			   (push (parse-result connection node) objects))
		       (dom:child-nodes document))
    objects))

(defmethod parse-result ((connection connection) (attribute dom-impl::attribute))
  (let* ((name (dom:node-name attribute))
	 (value (dom:value attribute))
	 (xml-attribute
	  (make-instance 'xml-attribute
			 :name name :value value :node attribute)))
    xml-attribute))

(defmethod parse-result ((connection connection) (node dom-impl::character-data))
  (let* ((name (dom:node-name node))
	 (data (dom:data node))
	 (xml-element (make-instance 'xml-element
				     :name name :data data :node node)))
    xml-element))

(defmethod parse-result ((connection connection) (node dom-impl::node))
  (let* ((name (intern (string-upcase (dom:node-name node)) :keyword))
	 (xml-element (make-instance 'xml-element :name name :node node)))
    (dom:do-node-list (attribute (dom:attributes node))
      (push (parse-result connection attribute) (attributes xml-element)))
    (dom:do-node-list (child (dom:child-nodes node))
      (push (parse-result connection child) (elements xml-element)))
    xml-element))


(defmethod xml-element-to-event ((connection connection) (object xml-element) (name (eql :iq)))
  (let ((id (intern (string-upcase (value (get-attribute object :id))) :keyword)))
    (if (not (string-equal (value (get-attribute object :type)) "result"))
	(make-error (get-element object :error))
      (case id
	(:error (make-error (get-element object :error)))
	(:roster_1 (make-roster object))
	(:reg2 :registration-successful)
	(:unreg_1 :registration-cancellation-successful)
	(:change1 :password-changed-succesfully)
	(:auth2 :authentication-successful)
	(t (cond
	    ((member id '(info1 info2 info3))
	     (make-disco-info (get-element object :query)))
	    ((member id '(items1 items2 items3 items4))
	     (make-disco-items (get-element object :query)))))))))

(defmethod xml-element-to-event ((connection connection)
				 (object xml-element) (name (eql :error)))
  (make-error object))

(defmethod xml-element-to-event ((connection connection)
				 (object xml-element) (name (eql :stream\:error)))
  (make-error object))

(defmethod xml-element-to-event ((connection connection)
				 (object xml-element) (name (eql :stream\:stream)))
  (setf (stream-id connection) (value (get-attribute object :id)))
  object)

(defmethod xml-element-to-event ((connection connection)
				 (object xml-element) (name (eql :stream\:features)))
  (dolist (element (elements object))
    (if (eq (name element) :mechanisms)
	(setf (mechanisms connection) (elements element))
      (push element (features connection))))
  object)

(defmethod xml-element-to-event ((connection connection) (object xml-element) name)
  (declare (ignore name))
  object)

(defmethod dom-to-event ((connection connection) (objects list))
  (map 'list #'(lambda (x) (dom-to-event connection x)) objects))

(defmethod dom-to-event ((connection connection) (object xml-element))
  (xml-element-to-event
   connection object (intern (string-upcase (name object)) :keyword)))

;;; XXX: Is the ask attribute of the <presence/> element part of the RFC/JEP?
(defmethod xml-element-to-event ((connection connection)
				 (object xml-element) (name (eql :presence)))
  (let ((show (get-element object :show)))
    (when show
      (setq show (data (get-element show :\#text))))
    (make-instance 'presence
                   :xml-element object
		   :from (value (get-attribute object :from))
		   :to (value (get-attribute object :to))
		   :show show
		   :type- (value (get-attribute object :type)))))

;;; XXX: Add support for the <thread/> element.  Also note that
;;; there may be an XHTML version of the body available in the
;;; original node but as of right now I don't care about it.  If
;;; you do please feel free to submit a patch.
(defmethod xml-element-to-event ((connection connection)
				 (object xml-element) (name (eql :message)))
  (make-instance 'message
                 :xml-element object
		 :from (value (get-attribute object :from))
		 :to (value (get-attribute object :to))
		 :body (data (get-element (get-element object :body) :\#text))))

;;
;; Receive stanzas
;;

(defmethod receive-stanza-loop ((connection connection)	&key
                                (stanza-callback 'default-stanza-callback)
                                dom-repr)
  "Reads from connection's stream and parses the XML received
on-the-go.  As soon as it has a complete element it calls
the stanza-callback (which by default eventually dispatches
to HANDLE)."
  (loop (receive-stanza connection
			:stanza-callback stanza-callback
			:dom-repr dom-repr)))

(defmethod receive-stanza ((connection connection) &key
			   (stanza-callback 'default-stanza-callback)
			   dom-repr)
  "Returns one stanza.  Hangs until one is received."
  (let* ((stanza (read-stanza connection))
	 (tagname (dom:tag-name (dom:document-element stanza))))
    (cond
     ((equal tagname "stream:error")
      (when stanza-callback
	(car (funcall stanza-callback stanza connection :dom-repr dom-repr)))
      (error "Received error."))
     (t
      (when stanza-callback
	(car (funcall stanza-callback stanza connection :dom-repr dom-repr)))))))

(defun read-stanza (connection)
  (unless (server-xstream connection)
    (setf (server-xstream connection)
          (cxml:make-xstream (server-stream connection))))
  (force-output (server-stream connection))
  (catch 'stanza
    (let ((cxml::*default-namespace-bindings*
           (acons "stream"
                  "http://etherx.jabber.org/streams"
                  cxml::*default-namespace-bindings*)))
      (cxml::parse-xstream (server-xstream connection)
                           (make-instance 'stanza-handler))
      (runes::write-xstream-buffer (server-xstream connection)))))
 
(defmacro with-xml-stream ((stream connection) &body body)
  "Helper macro to make it easy to control outputting XML
to the debug stream.  It's not strictly /with/ xml-stream
so it should probably be renamed."
  `(let ((,stream (server-stream ,connection)))
     (progn
       ,@body
       ,connection)))

(defun xml-output (stream string)
  "Write string to stream as a sequence of bytes and not characters."
  (let ((sequence (ironclad:ascii-string-to-byte-array string)))
    (write-sequence sequence stream)
    (finish-output stream)
    (when *debug-stream*
      (write-string string *debug-stream*)
      (force-output *debug-stream*))))

;;
;; Operators for communicating over the XML stream
;;

(defmethod begin-xml-stream ((connection connection))
  "Begin XML stream.  This should be the first thing to happen on a
newly connected connection."
  (with-xml-stream (stream connection)
   (xml-output stream "<?xml version='1.0' ?>")
   (xml-output stream (fmt "<stream:stream to='~a' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>" (or (jid-domain-part connection) (hostname connection))))))

(defmethod end-xml-stream ((connection connection))
  "Closes the XML stream.  At this point you'd have to
call BEGIN-XML-STREAM if you wished to communicate with
the server again."
  (with-xml-stream (stream connection)
   (xml-output stream "</stream:stream>")))

(defmacro with-iq ((connection &key id to (type "get")) &body body)
  "Macro to make it easier to write IQ stanzas."
  (let ((stream (gensym)))
    `(let ((,stream (server-stream ,connection)))
       (cxml:with-xml-output (make-octet+character-debug-stream-sink ,stream)
         (cxml:with-element "iq"
           (cxml:attribute "id" ,id)
           (when ,to
             (cxml:attribute "to" ,to))
           (cxml:attribute "type" ,type)
           ,@body))
       (force-output ,stream)
       ,connection)))

(defmacro with-iq-query ((connection &key xmlns id to node (type "get")) &body body)
  "Macro to make it easier to write QUERYs."
  `(progn
     (with-iq (connection :id ,id :type ,type :to ,to)
      (cxml:with-element "query"
       (cxml:attribute "xmlns" ,xmlns)
       (when ,node
         (cxml:attribute "node" ,node))
       ,@body))
    ,connection))

;;
;; Discovery
;;

(defmethod discover ((connection connection) &key (type :info) to node)
  (let ((xmlns
	 (case type
	   (:info "http://jabber.org/protocol/disco#info")
	   (:items "http://jabber.org/protocol/disco#items")
	   (t (error "Unknown type: ~a (Please choose between :info and :items)" type)))))
    (with-iq-query (connection :id "info1" :xmlns xmlns :to to :node node))))
  
;;
;; Basic operations
;;

(defmethod registration-requirements ((connection connection))
  (with-iq-query (connection :id "reg1" :xmlns "jabber:iq:register")))

(defmethod register ((connection connection) username password name email)
  (with-iq-query (connection :id "reg2" :type "set" :xmlns "jabber:iq:register")
   (cxml:with-element "username" (cxml:text username))
    (cxml:with-element "password" (cxml:text password))
    (cxml:with-element "name" (cxml:text name))
    (cxml:with-element "email" (cxml:text email))))

(defmethod cancel-registration ((connection connection))
  (with-iq-query (connection :id "unreg1" :type "set" :xmlns "jabber:iq:register")
   (cxml:with-element "remove")))

(defmethod change-password ((connection connection) new-password)
  (with-iq-query (connection :id "change1" :type "set" :xmlns "jabber:iq:register")
   (cxml:with-element "username"
    (cxml:text (username connection)))
   (cxml:with-element "password"
    (cxml:text new-password))))

(defmethod auth-requirements ((connection connection) username)
  (with-iq-query (connection :id "auth1" :xmlns "jabber:iq:auth")
   (cxml:with-element "username" (cxml:text username))))

(defmethod auth ((connection connection) username password
		 resource &optional (mechanism :plain))
  (setf (username connection) username)
  (funcall (get-auth-method mechanism) connection username password resource))

(defmethod %plain-auth% ((connection connection) username password resource)
  (with-iq-query (connection :id "auth2" :type "set" :xmlns "jabber:iq:auth")
   (cxml:with-element "username" (cxml:text username))
   (cxml:with-element "password" (cxml:text password))
   (cxml:with-element "resource" (cxml:text resource))))

(add-auth-method :plain #'%plain-auth%)

(defmethod %digest-md5-auth% ((connection connection) username password resource)
  (with-iq-query (connection :id "auth2" :type "set" :xmlns "jabber:iq:auth")
   (cxml:with-element "username" (cxml:text username))
   (if (stream-id connection)
       (cxml:with-element "digest"
	(cxml:text (make-digest-password (stream-id connection) password)))
     (error "stream-id on ~a not set, cannot make digest password" connection))
   (cxml:with-element "resource" (cxml:text resource))))

(add-auth-method :digest-md5 #'%digest-md5-auth%)

(defmethod presence ((connection connection) &key type to)
  (cxml:with-xml-output (make-octet+character-debug-stream-sink
			 (server-stream connection))
   (cxml:with-element "presence"
    (when type
      (cxml:attribute "type" type))
    (when to
      (cxml:attribute "to" to))))
  connection)
   
(defmethod message ((connection connection) to body)
  (cxml:with-xml-output (make-octet+character-debug-stream-sink
			 (server-stream connection))
   (cxml:with-element "message"
    (cxml:attribute "to" to)
    (cxml:with-element "body" (cxml:text body))))
  connection)

(defmethod bind ((connection connection) jid resource)
  (with-iq (connection :id "bind_2" :type "set")
   (cxml:with-element "bind"
    (cxml:attribute "xmlns" "urn:ietf:params:xml:ns:xmpp-bind")
    (cxml:with-element "resource"
     (cxml:text resource)))))

;;
;; Subscription
;;

(defmethod request-subscription ((connection connection) to)
  (presence connection :type "subscribe" :to to))

(defmethod approve-subscription ((connection connection) to)
  (presence connection :type "subscribed" :to to))

(defmethod deny/cancel-subscription ((connection connection) to)
  (presence connection :type "unsubscribed" :to to))

(defmethod unsubscribe ((connection connection) to)
  (presence connection :type "unsubscribe" :to to))

;;
;; Roster
;;

(defmethod get-roster ((connection connection))
  (with-iq-query (connection :id "roster_1" :xmlns "jabber:iq:roster")))

;;; Note: Adding and removing from the roster is not the same as
;;; adding and removing subscriptions.  I have not yet decided
;;; if the library should provide convenience methods for doing
;;; both actions at once.
(defmethod roster-add ((connection connection) jid name group)
  (with-iq-query (connection :id "roster_2" :type "set" :xmlns "jabber:iq:roster")
   (cxml:with-element "item"
    (cxml:attribute "jid" jid)
    (cxml:attribute "name" name)
    (cxml:with-element "group" group))))

(defmethod roster-remove ((connection connection) jid)
  (with-iq-query (connection :id "roster_4" :type "set" :xmlns "jabber:iq:roster")
   (cxml:with-element "item"
    (cxml:attribute "jid" jid)
    (cxml:attribute "subscription" "remove"))))

;;
;; Privacy list
;;

;;; Implemented in Jabberd2 and on which I have not tested with.
(defmethod get-privacy-lists ((connection connection))
  (with-iq-query (connection :id "getlist1" :xmlns "jabber:iq:privacy")))

(defmethod get-privacy-list ((connection connection) name)
  (with-iq-query (connection :id "getlist2" :xmlns "jabber:iq:privacy")
   (cxml:with-element "list"
    (cxml:attribute "name" name))))

