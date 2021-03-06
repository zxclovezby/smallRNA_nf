#!/usr/bin/env nextflow

/*
*****************************
 * Pipeline - smallRNA-meth *
 *                          *
 * Thomas R Burkard         *
 * IMP/IMBA Bioinformatics  *
 ****************************
*/


log.info """\
         =============================
         Pipeline - smallRNA-meth
         =============================

         outdir: ${params.outdir}
         reads: ${params.reads}
         adapter: ${params.adapter}
         adapterER: ${params.adapterER}
         minLength: ${params.minLength}
         maxLength: ${params.maxLength}
         minAlign: ${params.minAlign}
         genome: ${params.genome}
         contamination: ${params.contamination}
         spikeIn: ${params.spikeIn}
         gtf: ${params.gtf}
         gtfNoSplit: ${params.gtfNoSplit}
         tailFraction: ${params.tailFraction}
         cpus: ${params.cpus}
         memPerCPUSort: ${params.memPerCPUSort}
         """
         .stripIndent()


/*
 * Input parameters validation
 */
cont_file       = file(params.contamination)
if (params.spikeIn)
{
  spikeIn_file = file(params.spikeIn)
  //if( spikeIn_file.exists() ) println " spikeIn "
}

if (params.genome)
{
  genome_file = file(params.genome)
  if( !genome_file.exists() ) exit 1, "Genome file doesn't exist: ${genome_file}"
} else {
  exit 1, "Missing genome file"
}

if (params.gtf)
{
  gtf_file = file(params.gtf)
  if( !gtf_file.exists() ) exit 1, "GTF file doesn't exist: ${gtf_file}"
} else {
  gtf_file = file("NA")
}

if (params.gtfNoSplit)
{
  gtfNoSplit_file = file(params.gtfNoSplit)
  if( !gtfNoSplit_file.exists() ) exit 1, "GTF (no split) file doesn't exist: ${gtfNoSplit_file}"
} else {
  gtfNoSplit_file = file("NA")
}

if (( ! params.gtf ) && ( ! params.gtfNoSplit ))
{
  exit 1, "Neither --gtf nor --gtfNoSplit set"
}


/*
 * Validate input files
 */



/*
 * Create a channel for read files
 */
Channel
    .fromPath( params.reads)
    .ifEmpty { error "Cannot find any reads matching: ${params.reads}" }
    .map { file -> tuple(file.baseName, file) }
    .set { read_files }

/*
 * Cut adapter
 */
process cutadapt {
    tag "Channel: ${name}"

    publishDir "${params.outdir}/cutadapt", mode: 'copy', pattern: '*.err'

    input:
        set val(name), file(bam) from read_files

    output:
        set name, file("cutadapt.fastq") into fastq_cutadapt
	      set name, file("cutadapt.${name}.err") into stat_cutadapt
	      set name, file("cntTotal.txt") into cnt_total

    script:
    """
        PYTHON_EGG_CACHE=`pwd` #cutadapt wants to write into home FIXME
        export PYTHON_EGG_CACHE

        samtools view -c ${bam} > cntTotal.txt
        bamToFastq -i ${bam} -fq /dev/stdout |\
            cutadapt -e ${params.adapterER} -a ${params.adapter} -f fastq --overlap 5 --discard-untrimmed -o cutadapt.fastq - > cutadapt.${name}.err
    """
}

/*
 * Trim random nucleotides (UMI)
 */
process trimUMI {

    tag "Channel: ${name}"

    input:
        set name, file(fastq) from fastq_cutadapt

    output:
        set name, file("trimmed.fastq") into fastq_trimmed, fastq_trimmed2, fastq_for_spike
        set name, file("cntTrimmed.txt") into cnt_trimmed

    script:
    """
    cat ${fastq} |\
        paste - - - - |\
        perl ${baseDir}/scripts/trim.pl -m ${params.minLength} -M ${params.maxLength} > trimmed.fastq

    cat trimmed.fastq | paste - - - - | wc -l > cntTrimmed.txt
    """
}

/*
 * Trim spike in
 */
process trimSpike {

    tag "Channel: ${name}"

    when:
    spikeIn_file.exists()

    input:
        set name, file(fastq) from fastq_for_spike

    output:
        set name, file("spike.fastq") into fastq_spike
        //set name, file("cntTrimmed.txt") into cnt_trimmed

    script:
    """
    cat ${fastq} |\
        paste - - - - |\
        perl ${baseDir}/scripts/trim.pl -m 13 -M 13 > spike.fastq

    """
}
/*
 * Tailor index - spikeIn
 */
process buildTailorIndexSpikeIn {

    when:
    spikeIn_file.exists()

    input:
	   file genome from spikeIn_file

    output:
     file "index.tailor.spike*" into index_tailor_spikeIn

    script:
    """
    tailor_v1.1_linux_static build -i ${genome} -p index.tailor.spike

    """
}
/*
 * Align spike in with tailor
 */
process alignSpike {

    tag "Channel: ${name}"
    publishDir "${params.outdir}/spikeIns", mode: 'copy', pattern: '*.spike.bam'

    when:
    spikeIn_file.exists()

    input:
      file index from index_tailor_spikeIn
      set name, file(fastq) from fastq_spike

    output:
      set name, file("spike.bam") into bam_tailor_spike, bam_tailor_spike2
      file "${name}.spike.bam"

    script:
    """
    if [ -e index.tailor.spike.t_bwt.bwt ]; then
        tailor_v1.1_linux_static map -i ${fastq} -p index.tailor.spike -l 13 -n ${task.cpus} | samtools view -bS > spike.bam
    else
        touch spike.bam
    fi
    cp spike.bam ${name}.spike.bam

    """
}
/*
 * count reads and UMI for spike ins
 */
 process countSpike {
    tag "Channel: ${name}"
    publishDir "${params.outdir}/spikeIns", mode: 'copy', pattern: '*spikeIn.txt'

    when:
    spikeIn_file.exists()

    input:
    set name, file(spike_bam) from bam_tailor_spike

    output:
    file "${name}.spikeIn.txt" into spike_count

    script:
    """
    bash ${baseDir}/scripts/countSpikeIn.sh ${spike_bam} > ${name}.spikeIn.txt
    """

 }

/*
 * Tailor index
 */
process buildTailorIndex {

    input:
	    file genome from genome_file

    output:
      file "index.tailor*" into index_tailor

    script:
    """
    tailor_v1.1_linux_static build -i ${genome} -p index.tailor
    """
}

/*
 * Tailor index - contamination
 */
process buildTailorIndexContamination {

    input:
	   file genome from cont_file

    output:
     file "index.tailor.cont*" into index_tailor_cont

    script:
    """
    if [ ${genome} = "none" ]; then
        touch index.tailor.cont
    else
        tailor_v1.1_linux_static build -i ${genome} -p index.tailor.cont
    fi
    """
}


/*
 * Align with tailor to contamination
 */
process alignContamination {

    tag "Channel: ${name}"

    input:
      file index from index_tailor_cont
      set name, file(fastq) from fastq_trimmed

    output:
      set name, file("contamination.bam") into bam_tailor_cont, bam_tailor_cont2

    script:
    """
    if [ -e index.tailor.cont.t_bwt.bwt ]; then
        tailor_v1.1_linux_static map -i ${fastq} -p index.tailor.cont -l ${params.minAlign}  -n ${task.cpus} | samtools view -bS > contamination.bam
    else
        touch contamination.bam
    fi
    """
}

/*
 * Reads without contamination
 */

//phase 2 channels. Alternative see https://gitter.im/nextflow-io/nextflow/archives/2016/07/26
fastq_trimmed2.phase(bam_tailor_cont)
    .map { stat1, stat2 -> [stat1[0], stat1[1], stat2[1]] }
    .set{fastq_bam}


process cleanReads {

    tag "Channel: ${name}"

    input:
        set name, file(fastq), file(bam) from fastq_bam

    output:
        set name, file("cleanReads.fastq") into fastq_cleanReads

    script:
    """
    if [ -s ${bam} ]; then
        perl ${baseDir}/scripts/extract.unaligned.pl -b ${bam} -f ${fastq} > cleanReads.fastq
    else
        cp ${fastq} cleanReads.fastq
    fi
    """
}

/*
 * Align with tailor
 */
process align {

    tag "Channel: ${name}"

    input:
	   file index from index_tailor
     set name, file(fastq) from fastq_cleanReads

    output:
      set name, file("tailor.bam") into bam_tailor, bam_tailor2

    script:
    """
    tailor_v1.1_linux_static map -i ${fastq} -p index.tailor -l ${params.minAlign} -n ${task.cpus} | perl $baseDir/scripts/bam.NH2fraction.pl -m ${params.maxMultialign} | samtools view -bS > tailor.bam
    """
}


/*
 * Align stat
 */
process alignStat {

  tag "Channel: ${name}"

  input:
  set name, file(bam) from bam_tailor2

  output:
  set name, file("tailorStat.txt") into tailorStat

  script:
  """
  samtools sort -@ ${task.cpus} -n -m ${params.memPerCPUSort} -l 0 ${bam} | samtools view | cut -f 1  | uniq | wc -l > tailorStat.txt
  """
}


/*
 * Split GTF into 2 halfs (5'/3') and create antisense
 */
process splitAndMergeGTF {

    input:
        file gtf from gtf_file
        file gtfNoSplit from gtfNoSplit_file

    output:
        file "splitAndMerged.gtf" into gtf_split
	      file "splitAndMerged.as.gtf" into gtf_split_as

    shell:
    '''
    if [ "!{gtf}" != "NA" ]; then
      perl !{baseDir}/scripts/GTF.splitInHalf.pl !{gtf} > split.gtf
    else
      touch split.gtf
    fi

    if [ "!{gtfNoSplit}" != "NA" ]; then
      cat split.gtf !{gtfNoSplit} > splitAndMerged.gtf
    else
      mv split.gtf splitAndMerged.gtf
    fi

    perl -pe '@c = split "\t"; $c[6] =~ tr/+-/-+/; $c[1].="_AS"; $_=join "\t", @c; s/";/_AS";/g' splitAndMerged.gtf > splitAndMerged.as.gtf
    '''
}


/*
 * Assign reads to features. Multimappers as fraction of alignments
 */
process assignFeat {

    tag "Channel: ${name}"

    publishDir "${params.outdir}/seqCnt", mode: 'copy', pattern: '*.seqCnt.txt'

    input:
        set name, file(bam) from bam_tailor
	      file gtf from gtf_split
    output:
        set name, file("seqCnt.txt") into seq_cnt
        file "${name}.seqCnt.txt"

    script:
    """
    samtools view ${bam} |\
        htseq-count -s yes -m intersection-nonempty - ${gtf} -o assign.tmp

    egrep -v no_feature assign.tmp > assign2feat.tmp
    perl $baseDir/scripts/reduceBam.tailor.umi.pl -g ${gtf} -s assign2feat.tmp > seqCnt.txt
    cp seqCnt.txt ${name}.seqCnt.txt

    """
}

/*
 * Count feature (none hierarchical/no fixation)
 */
process countSimple {

    tag "Channel: ${name}"

    publishDir "${params.outdir}/count", mode: 'copy', pattern: '*count.txt'

    input:
	      set name, file(seq_cnt) from seq_cnt

    output:
        file "${name}.count.txt" into count
	      set name, file("totalFeatCnt.txt") into cnt_totalFeat

    shell:
    '''
    tail -n +2 !{seq_cnt} |\
        awk -vFS="\t" -vOFS="\t" -v CONVFMT="%.17g" -vTF="!{params.tailFraction}" \
        'BEGIN{print "Name", "GM", "PM", "Total", "GM.UMInum", "PM.UMInum", "Total.UMInum", "GM.UMIfr", "PM.UMIfr", "Total.UMIfr"} \
        {if ((length($10) / length($8)) <= TF) \
          { if ($11 == 0) { GM[$6] = GM[$6] + $12; GMumiNum[$6] = GMumiNum[$6] + $13; GMumiFr[$6] = GMumiFr[$6] + $14; \
          ID[$6] = 1; } \
            else { PM[$6] = PM[$6] + $12 ; PMumiNum[$6] = PMumiNum[$6] + $13; PMumiFr[$6] = PMumiFr[$6] + $14; \
            ID[$6] = 1; } \
          } \
        } \
        END{ Total=0; TotalUmiNum=0; TotalUmiFr=0; for (name in ID) \
        { Total=Total+GM[name]+PM[name];
        printf "%s\\t%.17g\\t%.17g\\t%.17g\\t%.17g\\t%.17g\\t%.17g\\t%.17g\\t%.17g\\t%.17g\\n", \
        name, GM[name], PM[name], GM[name]+PM[name], GMumiNum[name], PMumiNum[name], GMumiNum[name]+PMumiNum[name], GMumiFr[name], PMumiFr[name], GMumiFr[name]+PMumiFr[name]}; \
        print Total > "totalFeatCnt.txt"}' > !{name}.count.txt
    '''
}

/*
 * Pipeline count stats
 */

//phase many channels: https://gitter.im/nextflow-io/nextflow/archives/2016/07/26
/*
cnt_total.phase(cnt_trimmed)
    .map { stat1, stat2 -> [stat1[0], stat1[1], stat2[1]] }
    .phase(bam_tailor_cont2)
    .map { stat1, stat2 -> [stat1[0], stat1[1], stat1[2], stat2[1]] }
    .phase(bam_tailor2)
    .map { stat1, stat2 -> [stat1[0], stat1[1], stat1[2], stat1[3], stat2[1]] }
    .phase(cnt_totalFeat)
    .map { stat1, stat2 -> [stat1[0], stat1[1], stat1[2], stat1[3], stat1[4], stat2[1]] }
    .set{cntStat_files}
*/
// Short form of above
cnt_total.concat(cnt_trimmed, bam_tailor_cont2, tailorStat, cnt_totalFeat)
    .groupTuple()
    .map{ stat1, stat2 -> [stat1, stat2[0], stat2[1], stat2[2], stat2[3], stat2[4]] }
    .set{ cntStat_files }


process statTable {

    tag "Channel: ${name}"

    input:
        set name, file(cnt_total), file(cnt_trimmed), file(bam_tailor_cont), file(tailorStat), file(cnt_totalFeat) from cntStat_files

    output:
        file "${name}.countStat.txt" into cnt_stat


    script:
    """
    echo -e "Name\tTotal\tPassed trimming\tContamination align\tGenome align\tTotal reads in feature" > ${name}.countStat.txt
    TOTAL=`cat ${cnt_total}`
    TRIMMED=`cat ${cnt_trimmed}`
    CONT=`samtools view ${bam_tailor_cont} | cut -f 1 | sort -u | wc -l`
    TAILOR=`cat ${tailorStat}`
    FEATURE=`cat ${cnt_totalFeat}`

    echo -e "${name}\t\$TOTAL\t\$TRIMMED\t\$CONT\t\$TAILOR\t\$FEATURE" >> ${name}.countStat.txt
    """
}

/*
 * Big table of all samples
 */
process countTable {

    publishDir "${params.outdir}/result", mode: 'copy'

    input:
        file "count/*" from count.collect()
        file "spikeIn/*" from spike_count.collect()
	      file "countStat/*" from cnt_stat.collect()

    output:
        file "countTable.txt"
        file "spikeInTable.txt"
	      file "countTable.html"
	      file "countStatTable.txt"

    script:
    """
    cp $baseDir/scripts/countTable_UMI.Rmd ./countTable.Rmd
    R --slave -e "rmarkdown::render('countTable.Rmd')"

    """
}


workflow.onComplete {
    println "Pipeline completed at : $workflow.complete"
    println "Execution status      : ${ workflow.success ? 'succeeded' : 'failed' }"
    println "Duration : ${workflow.duration}"
}
